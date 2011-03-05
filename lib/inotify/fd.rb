require "rubygems"
require "ffi"
require "inotify/event"

module Inotify ; end

class Inotify::FD

  module CInotify
    extend FFI::Library
    ffi_lib FFI::Library::LIBC

    attach_function :inotify_init, [], :int
    attach_function :inotify_add_watch, [:int, :string, :uint32], :int
  end

  include CInotify

  WATCH_BITS = {
    :access => 1 << 0,
    :modify => 1 << 1,
    :attrib => 1 << 2,
    :close_write => 1 << 3,
    :close_nowrite => 1 << 4,
    :open => 1 << 5,
    :moved_from => 1 << 6,
    :moved_to => 1 << 7,
    :create => 1 << 8,
    :delete => 1 << 9,
    :delete_self => 1 << 10,
    :move_self => 1 << 11,

    # Shortcuts
    :close => (1 << 3) | (1 << 4),
    :move => (1 << 6) | (1 << 7) | (1 << 11),
    :delete => (1 << 9) | (1 << 10),
  }

  def initialize
    @watches = {}
    @fd = inotify_init
    @io = IO.for_fd(@fd)
  end

  # Add a watch.
  # - path is a string file path
  # - what_to_watch is any of the valid WATCH_BITS keys
  #
  # Example:
  #   watch("/tmp", :craete, :delete)
  def watch(path, *what_to_watch)
    mask = what_to_watch.inject(0) { |m, val| m |= WATCH_BITS[val] }
    watch_descriptor = inotify_add_watch(@fd, path, mask)
    #puts "watch #{path} => #{watch_descriptor}"

    if watch_descriptor == -1
      raise "inotify_add_watch(#{@fd}, #{path}, #{mask}) failed. #{$?}"
    end
    @watches[watch_descriptor] = path
  end

  # Read an inotify event.
  #
  # If timeout is not given, this call blocks.
  # If a timeout occurs and no event was read, nil is returned.
  #
  # If a code block is given, all available inotify events will
  # be yielded to the block. Otherwise, we return one event.
  def read(timeout=nil, &block)
    ready = IO.select([@io], nil, nil, timeout)

    return nil if ready == nil

    ready[0].each do |io|
      event = Inotify::Event.from_io(io)
      watchpath = @watches[event[:wd]]
      
      if event.name == nil
        # Some events don't have the name at all, so add our own.
        event.name = watchpath
      else
        # Event paths are relative to the watch. Prefix to make the full path.
        event.name = File.join(watchpath, event.name)
      end

      if block_given?
        yield event
      else
        # only gets one.
        return event
      end
    end # ready[0].each

    # No event was read due to timeout
    return nil
  end # def read
end # class Inotify::FD
