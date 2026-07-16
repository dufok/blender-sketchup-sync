# frozen_string_literal: true
# SU <-> Blender save-based sync — SketchUp side.
#
# Protocol (bridge folder ".su_blender_sync" next to the .skp/.blend files):
#   from_sketchup.glb / manifest_sketchup.json  — written by SketchUp
#   from_blender.glb  / manifest_blender.json   — written by Blender
#   state_sketchup.json                          — private state of this side
#
# Manifest: { "seq": N, "objects": { "<name>": { "rev": N, "deleted": bool } } }
# Receiver applies an object when incoming rev > locally known rev.
# Echo-loops are prevented by keeping the rev unchanged for objects whose local
# geometry hash hasn't changed since they were last applied/exported.

require 'sketchup.rb'
require 'json'
require 'digest'
require 'fileutils'

module StepanV
  module SuBlenderSync
    BRIDGE_DIR_NAME = '.su_blender_sync'
    OUT_GLB      = 'from_sketchup.glb'
    OUT_MANIFEST = 'manifest_sketchup.json'
    IN_GLB       = 'from_blender.glb'
    IN_MANIFEST  = 'manifest_blender.json'
    STATE_FILE   = 'state_sketchup.json'

    POLL_SECONDS   = 2.0
    SMOOTH_ANGLE   = 30.degrees   # soften edges below this dihedral angle
    NORMAL_EPS     = 0.5.degrees  # faces considered parallel below this
    COPLANAR_EPS   = 0.001        # inches: vertex distance to shared plane
    TEXTURE_MAX_PX = 1024

    # Sync is OFF by default; the toggle persists across sessions.
    @enabled       = Sketchup.read_default('su_blender_sync', 'enabled', false)
    @applying      = false
    @last_in_mtime = nil
    @observed      = {}

    class << self
      attr_accessor :enabled, :applying, :last_in_mtime

      def set_enabled(v)
        @enabled = v ? true : false
        Sketchup.write_default('su_blender_sync', 'enabled', @enabled)
      end

      # Guard against SketchUp auto-save: onPostSaveModel may fire when the
      # user did NOT explicitly save. A real save rewrites the .skp on disk,
      # so we only push when the file was written within the last seconds.
      def real_save?(model)
        p = model.path.to_s
        return false if p.empty? || !File.exist?(p)
        (Time.now - File.mtime(p)) < 5
      rescue StandardError
        false
      end

      # ------------------------------------------------------------ paths ---

      def bridge_dir(model)
        return nil if model.nil? || !model.valid? || model.path.to_s.empty?
        File.join(File.dirname(model.path), BRIDGE_DIR_NAME)
      end

      def read_state(dir)
        path = File.join(dir, STATE_FILE)
        return { 'seq' => 0, 'objects' => {} } unless File.exist?(path)
        JSON.parse(File.read(path))
      rescue StandardError
        { 'seq' => 0, 'objects' => {} }
      end

      def write_json(path, data)
        tmp = path + '.tmp'
        File.write(tmp, JSON.pretty_generate(data))
        File.delete(path) if File.exist?(path)
        File.rename(tmp, path)
      end

      # ----------------------------------------------------------- objects ---

      def top_objects(model)
        model.entities.to_a.select do |e|
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end
      end

      # A "collection group" is a top-level group created from a Blender
      # collection; marked with an attribute and tagged with its name.
      def collection_group?(e)
        e.is_a?(Sketchup::Group) &&
          e.get_attribute('su_blender_sync', 'collection')
      end

      def collection_groups(model)
        top_objects(model).select { |e| collection_group?(e) }
      end

      def ensure_collection_group(model, name)
        g = collection_groups(model).find { |e| e.name == name }
        return g if g
        g = model.entities.add_group
        g.name = name
        g.set_attribute('su_blender_sync', 'collection', true)
        g.layer = model.layers.add(name)
        g
      end

      def prune_empty_collection_groups(model)
        collection_groups(model).each do |g|
          g.erase! if g.valid? && definition_of(g).entities.size.zero?
        end
      end

      # All synced objects as [[instance, collection_name_or_nil], ...]:
      # top-level groups/components, plus children of collection groups.
      def sync_units(model)
        units = []
        top_objects(model).each do |e|
          if collection_group?(e)
            definition_of(e).entities.to_a.each do |c|
              next unless c.is_a?(Sketchup::Group) ||
                          c.is_a?(Sketchup::ComponentInstance)
              units << [c, e.name]
            end
          else
            units << [e, nil]
          end
        end
        units
      end

      def find_sync_object(model, name)
        sync_units(model).each do |inst, _c|
          return inst if inst.name == name
        end
        nil
      end

      # Give stable names to unnamed top-level groups/instances (pre-save).
      def ensure_names(model)
        unnamed = sync_units(model).map(&:first).select { |e| e.name.to_s.empty? }
        return if unnamed.empty?
        model.start_operation('Sync: name objects', true)
        unnamed.each { |e| e.name = format('Obj_%06x', rand(0xffffff)) }
        model.commit_operation
      rescue StandardError => err
        log("ensure_names: #{err}")
      end

      # Geometry hash — local change detection only (never compared cross-app).
      def local_hash(inst)
        d = Digest::MD5.new
        d.update(inst.transformation.to_a.map { |f| f.round(4) }.join(','))
        hash_entities(definition_of(inst).entities, d, {})
        d.hexdigest
      end

      def hash_entities(ents, d, visited)
        ents.each do |e|
          if e.is_a?(Sketchup::Face)
            e.vertices.each do |v|
              p = v.position
              d.update("#{p.x.to_f.round(3)},#{p.y.to_f.round(3)},#{p.z.to_f.round(3)};")
            end
            d.update(e.material ? e.material.name : '-')
            d.update(e.back_material ? e.back_material.name : '-')
          elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
            d.update(e.transformation.to_a.map { |f| f.round(4) }.join(','))
            df = definition_of(e)
            next if visited[df]
            visited[df] = true
            hash_entities(df.entities, d, visited)
          end
        end
      end

      def definition_of(inst)
        inst.respond_to?(:definition) ? inst.definition : inst
      end

      # -------------------------------------------------------------- push ---

      def push!(model)
        dir = bridge_dir(model)
        unless dir
          log('push skipped: model not saved yet')
          return
        end
        FileUtils.mkdir_p(dir)
        state = read_state(dir)
        rev_new = state['seq'].to_i + 1
        changed = false
        seen = {}

        sync_units(model).each do |inst, cname|
          name = inst.name.to_s
          next if name.empty?
          seen[name] = true
          h  = local_hash(inst)
          st = state['objects'][name]
          if st && st['local_hash'] == h && st['collection'] == cname &&
             !st['deleted']
            next # unchanged since last apply/export — keep rev (no echo)
          end
          state['objects'][name] = {
            'rev' => rev_new, 'origin' => 'sketchup', 'local_hash' => h,
            'collection' => cname
          }
          changed = true
        end

        # tombstones for locally deleted objects
        state['objects'].each do |name, st|
          next if seen[name] || st['deleted']
          state['objects'][name] = { 'rev' => rev_new, 'origin' => 'sketchup',
                                     'deleted' => true }
          changed = true
        end

        state['seq'] = rev_new if changed

        export_glb(model, File.join(dir, OUT_GLB))
        manifest = {
          'seq' => state['seq'], 'saved_at' => Time.now.to_i,
          'objects' => state['objects'].each_with_object({}) do |(n, st), h2|
            h2[n] = { 'rev' => st['rev'], 'deleted' => !!st['deleted'],
                      'collection' => st['collection'] }
          end
        }
        # manifest written AFTER the glb so the receiver never sees a half file
        write_json(File.join(dir, OUT_MANIFEST), manifest)
        write_json(File.join(dir, STATE_FILE), state)
        Sketchup.status_text = 'SU⇄Blender: pushed to bridge.'
      rescue StandardError => err
        log("push!: #{err}\n#{err.backtrace.first(5).join("\n")}")
      end

      def export_glb(model, path)
        ok = begin
          model.export(path, show_summary: false)
        rescue ArgumentError, TypeError
          model.export(path, false)
        end
        log('GLB export returned false — is glTF export available (SU 2025+)?') unless ok
        ok
      end

      # -------------------------------------------------------------- pull ---

      def pull!(model, force = false)
        return if @applying
        dir = bridge_dir(model)
        return unless dir
        mpath = File.join(dir, IN_MANIFEST)
        return unless File.exist?(mpath)
        mt = File.mtime(mpath)
        return if !force && mt == @last_in_mtime
        @last_in_mtime = mt

        # don't touch the model while user is editing inside a group/component
        return if model.respond_to?(:active_path) && model.active_path

        manifest = JSON.parse(File.read(mpath))
        state    = read_state(dir)
        to_apply = []
        to_del   = []
        (manifest['objects'] || {}).each do |name, o|
          cur = state['objects'][name]
          cur_rev = cur ? cur['rev'].to_i : -1
          next unless o['rev'].to_i > cur_rev
          if o['deleted']
            to_del << [name, o['rev']]
          else
            to_apply << [name, o['rev'], o['collection']]
          end
        end
        return if to_apply.empty? && to_del.empty?

        @applying = true
        apply_deletions(model, to_del, state) unless to_del.empty?
        apply_imports(model, dir, to_apply, state) unless to_apply.empty?
        write_json(File.join(dir, STATE_FILE), state)
        Sketchup.status_text =
          "SU⇄Blender: applied #{to_apply.size} change(s), #{to_del.size} deletion(s) from Blender."
      rescue StandardError => err
        log("pull!: #{err}\n#{err.backtrace.first(5).join("\n")}")
      ensure
        @applying = false
      end

      def apply_deletions(model, to_del, state)
        model.start_operation('Sync: delete from Blender', true)
        to_del.each do |name, rev|
          obj = find_sync_object(model, name)
          obj.erase! if obj
          state['objects'][name] = { 'rev' => rev, 'origin' => 'blender',
                                     'deleted' => true }
        end
        prune_empty_collection_groups(model)
        model.commit_operation
      end

      def apply_imports(model, dir, to_apply, state)
        defs_before = model.definitions.to_a
        container   = import_glb(model, File.join(dir, IN_GLB))
        unless container
          log('pull: GLB import produced no container — aborting apply')
          return
        end
        new_defs = model.definitions.to_a - defs_before

        model.start_operation('Sync: apply from Blender', true)
        ct       = container.transformation
        children = definition_of(container).entities.to_a.select do |e|
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end
        # name -> [entity, world_transform]; index one level deeper too, in
        # case the sender wrapped objects into collection nodes
        by_name = {}
        children.each do |c|
          n = c.name.to_s
          n = definition_of(c).name.to_s if n.empty?
          by_name[n] = [c, ct * c.transformation] unless n.empty?
          definition_of(c).entities.to_a.each do |cc|
            next unless cc.is_a?(Sketchup::Group) ||
                        cc.is_a?(Sketchup::ComponentInstance)
            nn = cc.name.to_s
            next if nn.empty? || by_name.key?(nn)
            by_name[nn] = [cc, ct * c.transformation * cc.transformation]
          end
        end

        mats_touched = {}
        to_apply.each do |name, rev, cname|
          src, wt = by_name[name] ||
                    by_name.find { |k, _| k.sub(/[#.]\d+$/, '') == name }&.last
          unless src
            log("pull: object '#{name}' not found in incoming GLB")
            next
          end
          old = find_sync_object(model, name)
          old.erase! if old
          parent = cname ? ensure_collection_group(model, cname).entities
                         : model.entities
          ni = parent.add_instance(definition_of(src), wt)
          ni.name = name
          ni.layer = model.layers.add(cname) if cname
          cleanup!(ni, mats_touched)
          state['objects'][name] = {
            'rev' => rev, 'origin' => 'blender',
            'local_hash' => local_hash(ni), 'collection' => cname
          }
        end

        container.erase! if container.valid?
        prune_empty_collection_groups(model)
        shrink_textures(mats_touched.keys)
        model.commit_operation

        # drop leftover imported definitions that ended up unused
        if model.definitions.respond_to?(:remove)
          new_defs.each do |df|
            model.definitions.remove(df) if df.valid? && df.instances.empty?
          rescue StandardError
            nil
          end
        end
      end

      def import_glb(model, path)
        ents_before = model.entities.to_a
        defs_before = model.definitions.to_a
        begin
          model.import(path, show_summary: false)
        rescue ArgumentError, TypeError
          model.import(path, false)
        end
        new_top = model.entities.to_a - ents_before
        inst = new_top.find do |e|
          e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        end
        return inst if inst
        # some importers only add a definition without placing it
        new_defs = model.definitions.to_a - defs_before
        root = new_defs.find { |d| d.instances.empty? } || new_defs.last
        root ? model.entities.add_instance(root, Geom::Transformation.new) : nil
      end

      # ----------------------------------------------------------- cleanup ---
      # Merge coplanar triangles, soften curved-surface edges, collect
      # materials for texture shrinking. Runs on freshly imported instances.

      def cleanup!(inst, mats_touched, visited = {})
        df = definition_of(inst)
        return if visited[df]
        visited[df] = true
        ents = df.entities

        merge_coplanar(ents)
        soften_and_collect(ents, mats_touched)

        ents.to_a.each do |e|
          if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
            cleanup!(e, mats_touched, visited)
          end
        end
      end

      def merge_coplanar(ents)
        passes = 0
        loop do
          merged = 0
          ents.grep(Sketchup::Edge).each do |e|
            next unless e.valid?
            fs = e.faces
            next unless fs.size == 2
            f1, f2 = fs
            next unless f1.material == f2.material
            next unless f1.back_material == f2.back_material
            next unless f1.normal.angle_between(f2.normal) < NORMAL_EPS
            plane = f1.plane
            coplanar = f2.vertices.all? do |v|
              v.position.distance_to_plane(plane) < COPLANAR_EPS
            end
            next unless coplanar
            e.erase!
            merged += 1
          end
          passes += 1
          break if merged.zero? || passes >= 5
        end
        # stray edges left behind by merging
        ents.grep(Sketchup::Edge).each do |e|
          e.erase! if e.valid? && e.faces.empty?
        end
      end

      def soften_and_collect(ents, mats_touched)
        ents.grep(Sketchup::Edge).each do |e|
          next unless e.valid? && e.faces.size == 2
          ang = e.faces[0].normal.angle_between(e.faces[1].normal)
          if ang > NORMAL_EPS && ang < SMOOTH_ANGLE
            e.soft = true
            e.smooth = true
          end
        end
        ents.grep(Sketchup::Face).each do |f|
          mats_touched[f.material] = true if f.material
          mats_touched[f.back_material] = true if f.back_material
        end
      end

      def shrink_textures(materials)
        materials.compact.each do |m|
          tex = m.texture
          next unless tex
          ir = begin
            tex.image_rep
          rescue StandardError
            nil
          end
          next unless ir
          w = ir.width
          h = ir.height
          next if w <= TEXTURE_MAX_PX && h <= TEXTURE_MAX_PX
          scale = TEXTURE_MAX_PX.to_f / [w, h].max
          size_l = tex.width  # keep model-unit tiling size
          size_h = tex.height
          downscale_image_rep(ir, (w * scale).round, (h * scale).round)
          m.texture = ir
          begin
            m.texture.size = [size_l, size_h]
          rescue StandardError
            nil
          end
        rescue StandardError => err
          log("shrink_textures(#{m.name}): #{err}")
        end
      end

      # nearest-neighbour, pure Ruby (runs only on save-sync, so speed is OK)
      def downscale_image_rep(ir, nw, nh)
        w   = ir.width
        h   = ir.height
        bpp = ir.bits_per_pixel / 8
        row = w * bpp + ir.row_padding
        src = ir.data
        out = String.new(capacity: nw * nh * bpp)
        nh.times do |y|
          sy = y * h / nh
          nw.times do |x|
            sx = x * w / nw
            out << src[sy * row + sx * bpp, bpp]
          end
        end
        ir.set_data(nw, nh, bpp * 8, 0, out)
      end

      # -------------------------------------------------------------- misc ---

      def log(msg)
        puts "[SU⇄Blender] #{msg}"
      end

      def attach(model)
        return if model.nil? || !model.valid?
        key = model.guid rescue model.object_id
        return if @observed[key]
        @observed[key] = true
        model.add_observer(SyncModelObserver.new)
        @last_in_mtime = nil # fresh model — allow first pull
      end

      def poll_tick
        return unless @enabled && !@applying
        m = Sketchup.active_model
        pull!(m, false) if m
      rescue StandardError => err
        log("poll: #{err}")
      end
    end

    # ------------------------------------------------------------ observers ---

    class SyncModelObserver < Sketchup::ModelObserver
      def onPreSaveModel(model)
        SuBlenderSync.ensure_names(model) if SuBlenderSync.enabled
      end

      def onPostSaveModel(model)
        return unless SuBlenderSync.enabled
        return unless SuBlenderSync.real_save?(model) # skip auto-save
        SuBlenderSync.push!(model)
      end
    end

    class SyncAppObserver < Sketchup::AppObserver
      def onOpenModel(model)
        SuBlenderSync.attach(model)
      end

      def onNewModel(model)
        SuBlenderSync.attach(model)
      end

      def expectsStartupModelNotifications
        true
      end
    end

    # ------------------------------------------------------------------ UI ---

    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu('SU ⇄ Blender Sync')
      menu.add_item('Pull from Blender now') do
        SuBlenderSync.pull!(Sketchup.active_model, true)
      end
      menu.add_item('Push to Blender now') do
        m = Sketchup.active_model
        SuBlenderSync.ensure_names(m)
        SuBlenderSync.push!(m)
      end
      menu.add_item('Open bridge folder') do
        dir = SuBlenderSync.bridge_dir(Sketchup.active_model)
        dir ? UI.openURL("file:///#{dir.tr('\\', '/')}") : UI.messagebox('Save the model first.')
      end
      item = menu.add_item('Enabled') do
        SuBlenderSync.set_enabled(!SuBlenderSync.enabled)
      end
      menu.set_validation_proc(item) do
        SuBlenderSync.enabled ? MF_CHECKED : MF_UNCHECKED
      end

      Sketchup.add_observer(SyncAppObserver.new)
      SuBlenderSync.attach(Sketchup.active_model) if Sketchup.active_model
      UI.start_timer(POLL_SECONDS, true) { SuBlenderSync.poll_tick }

      file_loaded(__FILE__)
    end
  end
end
