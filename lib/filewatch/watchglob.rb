require "filewatch/namespace"
require "filewatch/exception"
require "filewatch/watch"

class FileWatch::WatchGlob
  attr_accessor :logger

  # This class exists to wrap inotify, kqueue, periodic polling, etc,
  # to provide you with a way to watch files and directories.
  #
  # For now, it only supports inotify.
  def initialize
    @watch = FileWatch::Watch.new
    @globdirs = []
    @globs = []
    @logger = Logger.new(STDERR)
  end

  public
  def watch(glob, *what_to_watch, &block)
    @globs << [glob, what_to_watch]

    watching = [] 
    errors = []
    paths = Dir.glob(glob)
    paths.each do |path|
      begin
        next if watching.include?(path)
        @logger.info("Watching #{path}")
        @watch.watch(path, :create, :delete, :modify)
        watching << path

        # Yield each file found by glob to the block.
        # This allows initialization on new files found at start.
        yield path if block_given?
      rescue FileWatch::Exception => e
        @logger.info("Failed starting watch on #{path} - #{e}")
        errors << e
      end
    end

    # Go through the glob and look for paths leading into a '*'
    splitpath = glob.split(File::SEPARATOR)
    splitpath.each_with_index do |part, i|
      current = File.join(splitpath[0 .. i])
      current = "/" if current.empty?
      next if watching.include?(current)
      # TODO(sissel): Do better glob detection
      if part.include?("*")
        globprefix = File.join(splitpath[0 ... i])
        Dir.glob(globprefix).each do |path|
          next if watching.include?(path)
          @logger.info("Watching dir: #{path.inspect}")
          @watch.watch(path, :create)
          @globdirs << path
        end # Dir.glob
      end # if part.include?("*")
    end # splitpath.each_with_index
  end # def watch

  # TODO(sissel): implement 'unwatch' or cancel?

  def subscribe(handler=nil, &block)
    @watch.subscribe do |event|
      # If this event is a directory event and the file matches a watched glob,
      # then it should be a new-file creation event. Watch the file.
      if event.type == :directory and @globdirs.include?(File.dirname(event.name))
        glob, what = @globs.find { |glob, what| File.fnmatch?(glob, event.name) }
        if glob
          @watch.watch(event.name, *what)
        end
      end

      # Push the event to our callback.
      block.call event
    end
  end

  def each(&block)
    @inotify.each(&block)
  end # def each
end # class FileWatch::Watch
