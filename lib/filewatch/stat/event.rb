require "filewatch/stat/fd"
require "filewatch/namespace"
require "filewatch/rubyfixes"

class FileWatch::Stat::Event
  attr_accessor :actions
  attr_accessor :name

  def initialize(name, actions)
    @name, @actions = name, [*actions]
  end
end
