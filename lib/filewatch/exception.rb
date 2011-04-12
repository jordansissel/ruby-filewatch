require "filewatch/namespace"

class FileWatch::Exception < Exception
  attr_accessor :fd
  attr_accessor :path

  def initialize(message, fd, path)
    super(message)
    @fd = fd
    @path = path
  end
end
