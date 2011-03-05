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
    #@fd = inotify_init
    #@io = IO.for_fd(@fd)
  end

  def watch(path, *what_to_watch)
    if !@watches.has_value?(path)
      io = IO.for_fd(inotify_init)
      @watches[io] = path
    else
      @watches.each do |watched_io, watched_path|
        if watched_path == path
          io = watched_io
          break
        end
      end
    end

    mask = what_to_watch.inject(0) { |m, val| m |= WATCH_BITS[val] }
    return inotify_add_watch(io.fileno, path, mask)
  end

  def read(&block)
    ready = IO.select(@watches.keys, nil, nil, nil)

    ready[0].each do |io|
      event = Inotify::Event.from_io(io)

      if block_given?
        yield event
      else
        # only gets one.
        return event
      end
    end # ready[0].each
  end # def read
end # class Inotify::FD
