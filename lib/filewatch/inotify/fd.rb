require "rubygems"
require "ffi"
require "fcntl"
require "filewatch/exception"
require "filewatch/inotify/event"
require "filewatch/namespace"
require "filewatch/rubyfixes"
require "filewatch/stringpipeio"

class FileWatch::Inotify::FD
  include Enumerable

  module CInotify
    extend FFI::Library
    ffi_lib FFI::Library::LIBC

    attach_function :inotify_init, [], :int
    attach_function :fcntl, [:int, :int, :long], :int
    attach_function :inotify_add_watch, [:int, :string, :uint32], :int

    # So we can read and poll inotify from jruby.
    attach_function :read, [:int, :pointer, :size_t], :int

    # Poll is pretty crappy, but it's better than nothing.
    attach_function :poll, [:pointer, :int, :int], :int
  end

  INOTIFY_CLOEXEC = 02000000
  INOTIFY_NONBLOCK = 04000
  
  F_SETFL = 4
  O_NONBLOCK = 04000  

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
  }

    # Shortcuts
  WATCH_BITS[:close] = WATCH_BITS[:close_write] | WATCH_BITS[:close_nowrite]
  WATCH_BITS[:move] = WATCH_BITS[:moved_from] \
                      | WATCH_BITS[:moved_to] | WATCH_BITS[:move_self]
  WATCH_BITS[:delete] = WATCH_BITS[:delete] | WATCH_BITS[:delete_self]

  attr_reader :fd

  public
  def self.can_watch?(filestat)
    # TODO(sissel): implement.
    return true
  end # def self.can_watch?

  # Create a new FileWatch::Inotify::FD instance.
  # This is the main interface you want to use for watching
  # files, directories, etc.
  public
  def initialize
    @watches = {}
    @buffer = FileWatch::StringPipeIO.new

    # Can't use inotify_init1 since older kernels don't have it.
    # Implement nonblock ourselves.
    @fd = CInotify.inotify_init()

    # Track movement cookies # since 'moved_from' and 'moved_to' are separate
    # events.
    @movement = {}

    if java?
      @io = nil
      @rc = CInotify.fcntl(@fd, F_SETFL, O_NONBLOCK)
      if @rc == -1
        raise FileWatch::Exception.new(
          "fcntl(#{@fd}, F_SETFL, O_NONBLOCK) failed. #{$?}", @fd, nil)
      end
    else
      @io = IO.for_fd(@fd)
      @io.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
    end
  end

  # Are we using java?
  private
  def java?
    return RUBY_PLATFORM == "java"
  end

  # Add a watch.
  # - path is a string file path
  # - what_to_watch is any of the valid WATCH_BITS keys
  #
  # Possible values for what_to_watch:
  #   (See also the inotify(7) manpage under 'inotify events'
  #
  #   :access   - file was accesssed (a read)
  #   :attrib   - permissions, timestamps, link count, owner, etc changed
  #   :close_nowrite  - a file not opened for writing was closed
  #   :close_write    - a file opened for writing was closed
  #   :create   - file/directory was created, only valid on watched directories
  #   :delete   - file/directory was deleted, only valid on watched directories
  #   :delete_self - a watched file or directory was deleted
  #   :modify      - A watched file was modified
  #   :moved_from  - A file was moved out of a watched directory
  #   :moved_to    - A file was moved into a watched directory
  #   :move_self   - A watched file/directory was moved
  #   :open        - A file was opened
  #   # Shortcuts
  #   :close  - close_nowrite or close_write
  #   :move   - move_self or moved_from or moved_to
  #   :delete - delete or delete_self
  #  
  # (Some of the above data copied from the inotify(7) manpage, which comes from
  #  the linux man-pages project. http://www.kernel.org/doc/man-pages/ )
  #
  # Example:
  #   fd = FileWatch::Inotify::FD.new
  #   fd.watch("/tmp", :create, :delete)
  #   fd.watch("/var/log/messages", :modify)
  public
  def watch(path, *what_to_watch)
    mask = what_to_watch.inject(0) { |m, val| m |= WATCH_BITS[val] }
    watch_descriptor = CInotify.inotify_add_watch(@fd, path, mask)

    if watch_descriptor == -1
      raise FileWatch::Exception.new(
        "inotify_add_watch(#{@fd}, #{path}, #{mask}) failed. #{$?}", @fd, path)
    end

    @watches[watch_descriptor] = {
      :path => path,
      :partial => nil,
      :is_directory => File.directory?(path),
    }
    return watch_descriptor
  end # def watch

  # TODO(sissel): Implement inotify_rm_watch as 'cancel'

  private
  def normal_read(timeout=nil)
    loop do
      begin
        data = @io.sysread(4096)
        @buffer.write(data)
      rescue Errno::EAGAIN
        # No data left to read, moveon.
        break
      end
    end
    return nil
  end # def normal_read

  private
  def jruby_read(timeout=nil)
    # TODO(sissel): instantiate this once to prevent extra memory usage? safe?
    @jruby_read_buffer = FFI::MemoryPointer.new(:char, 4096)

    # TODO(sissel): Block with select.
    # Will have to use FFI to call select, too.

    # We have to call libc's read(2) because JRuby/Java can't trivially
    # be told about existing file descriptors.
    loop do
      bytes = CInotify.read(@fd, @jruby_read_buffer, 4096)

      # read(2) returns -1 on error, which we expect to be EAGAIN, but...
      # TODO(sissel): maybe we should check errno properly...  Then again,
      # errno is supposedly thread-safe, but I believe that is in reference to
      # pthreads. Ruby's green threads, fibers, etc, are not likely subject to
      # the same safeties, so we have to assume errno is effed.
      # This code is run in jruby only, so maybe we can guarantee that
      # a thread is a pthread and has errno safety. Which leads us to the next
      # question - how to access errno from jruby/ffi?
      break if bytes == -1

      @buffer.write(@jruby_read_buffer.get_bytes(0, bytes))
    end
    return nil
  end # def jruby_read
    
  # Make any necessary corrections to the event
  private
  def prepare(event)
    watch = @watches[event[:wd]]

    if event.name == nil
      # Some events don't have the name at all, so add what we know.
      # This usually occurs on events for files where inotify expects us to
      # track the file name anyway.
      event.name = watch[:path]
      event.type = :file
    else
      # In cases where we have event names, they are always(?) directory events
      # and contain the name of the file changed.  Event paths are relative to
      # the watch, if a directory. Prefix to make the full path.
      if watch[:is_directory]
        event.name = File.join(watch[:path], event.name)
        event.type = :directory
      end
    end

    return event
  end # def prepare

  # Get one inotify event.
  #
  # TIMEOUT NOT SUPPORTED YET;
  #
  # If timeout is not given, this call blocks.
  # If a timeout occurs and no event was read, nil is returned.
  #
  # Returns nil on timeout or an FileWatch::Inotify::Event on success.
  private
  def get(timeout_not_supported_yet=nil)
    # This big 'loop' is to support pop { |event| ... } shipping each available event.
    # It's not very rubyish (we should probably use Enumerable and such.
    if java?
      #jruby_read(timeout)
      jruby_read
    else
      #normal_read(timeout)
      normal_read
    end

    # Recover any previous partial event.
    if @partial
      event = @partial.from_stringpipeio(@buffer)
    else
      event = FileWatch::Inotify::Event.from_stringpipeio(@buffer)
      return nil if event == nil
    end

    if event.partial?
      @partial = event
      return nil
    end
    @partial = nil

    return prepare(event)
  end # def get

  # For Enumerable support
  # 
  # Yields one FileWatch::Inotify::Event per iteration. If there are no more events
  # at the this time, then this method will end.
  public
  def each(&block)
    loop do
      event = get
      break if event == nil

      # inotify claims to guarantee order of events, so we should always see
      # 'moved_from' events before 'moved_to'
      if event.actions.include?(:moved_from)
        @movement[event.cookie] = event.name
      end

      if event.actions.include?(:moved_to) and @movement.include?(event.cookie)
        event.old_name = @movement[event.cookie]
        @movement.delete(event.cookie)

        # If we are watching this file, update the path with the new filename
        @watches.each do |wd, watch|
          if watch[:path] == event.old_name
            watch[:old_path] = watch[:path]
            watch[:path] = event.name
          end
        end # @watches.each
      end # if event.actions.include? :moved_to

      # We're dong mangling the event. Ship it.
      yield event
    end # loop
  end # def each

  # Subscribe to inotify events for this instance.
  # 
  # If you are running in EventMachine, this will set up a 
  # subscription that behaves sanely in EventMachine
  #
  # If you are not running in EventMachine, this method
  # blocks forever, invoking the given block for each event.
  # Further, if you are not using EventMachine, you should
  # not pass a handler, only a block, like this:
  #
  #   fd.subscribe do |event|
  #     puts event
  #   end
  public
  def subscribe(handler=nil, &block)
    if defined?(EventMachine) && EventMachine.reactor_running?
      require "filewatch/inotify/emhandler"
      handler = FileWatch::Inotify::EMHandler if handler == nil
      EventMachine::watch(@fd, handler, self, block)
    else
      loop do
        if java?
          # No way to select on FFI-derived file descriptors yet,
          # when I grab poll(2) via FFI, this sleep will become
          # a poll or sleep invocation.
          sleep(1)
        else
          IO.select([@io], nil, nil, nil)
        end
        each(&block)
      end
    end
  end
end # class FileWatch::Inotify::FD
