require "rubygems"
require "inotify/namespace"

class Inotify::StringPipeIO
  def initialize
    @buffer = ""
  end # def initialize

  def write(string)
    @buffer += string
  end # def write

  def read(bytes=nil, nil_if_not_enough_data=false)
    return nil if @buffer == nil || @buffer.empty?

    if nil_if_not_enough_data && bytes > @buffer.size
      return nil
    end

    bytes = @buffer.size if bytes == nil
    data = @buffer[0 .. bytes]
    if bytes <= @buffer.length
      @buffer = @buffer[bytes .. -1]
    else
      @buffer = ""
    end
    return data
  end # def read

  def size
    return @buffer.size
  end
end # class Inotify::StringPipeIO
