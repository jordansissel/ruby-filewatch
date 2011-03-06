require "inotify/namespace"
require "inotify/fd"
require "ffi"

class Inotify::Event < FFI::Struct
  layout :wd, :int,
         :mask, :uint32,
         :cookie, :uint32,
         :len, :uint32
  # last piece is the name, but don't hold it in the struct
         #:name, :string,

  attr_accessor :name

  def initialize(pointer)
    if pointer.is_a?(String)
      pointer = FFI::MemoryPointer.from_string(pointer)
    end

    super(pointer)
  end

  def self.from_stringpipeio(io)
    # This fails in ruby 1.9.2 because it literally calls read(2) with
    # 'self.size' as the byte size to read. This causes EINVAL 
    # from inotify, documented thusly in inotify(7):
    # 
    # """ The  behavior  when  the buffer given to read(2) is too small to
    #     return information about the next event depends on the  kernel
    #     version:  in  kernels  before  2.6.21, read(2) returns 0; since
    #     kernel 2.6.21, read(2) fails with the error EINVAL. """
    #
    # Working around this will require implementing our own read buffering
    # unless comeone clues me in on how to make ruby 1.9.2 read larger
    # blocks and actually do the nice buffered IO we've all come to
    # know and love.

    begin
      data = io.read(self.size, true)
    rescue Errno::EINVAL => e
      $stderr.puts "Read was too small? Confused."
      raise e
    end

    return nil if data == nil

    pointer = FFI::MemoryPointer.from_string(data)
    event = self.new(pointer)

    event.from_stringpipeio(io)
    return event
  end

  def from_stringpipeio(io)
    begin
      @name = io.read(self[:len], true)
    rescue Errno::EINVAL => e
      $stderr.puts "Read was too small? Confused."
      raise e
    end
    return self if @name == nil

    @name = @name.split("\0", 2).first

    return self
  end

  def actions
    Inotify::FD::WATCH_BITS.reject do |key, bitmask| 
      self[:mask] & bitmask == 0 
    end.keys
  end

  def to_s
    return "#{@name} (#{self.actions.join(", ")})"
  end

  def partial?
    return self[:len] > 0 && @name == nil
  end # def partial?
end
