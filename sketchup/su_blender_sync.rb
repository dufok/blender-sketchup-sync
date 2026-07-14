# su_blender_sync.rb — loader
# SU <-> Blender save-based sync bridge.
require 'sketchup.rb'
require 'extensions.rb'

module StepanV
  module SuBlenderSync
    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('SU ⇄ Blender Sync', 'su_blender_sync/core')
      ex.description = 'Save-based sync of geometry and materials with Blender via a GLB bridge folder.'
      ex.version     = '0.2.0'
      ex.creator     = 'Stepan'
      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end
  end
end
