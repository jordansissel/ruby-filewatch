require "filewatch/namespace"
require "filewatch/watch"

class FileWatch::Tail
  attr_accessor :logger

  public
  def initialize
    @watch = FileWatch::Watch.new
    @files = {}
    @logger = Logger.new(STDERR)
  end # def initialize

  public
  def watch(path, opts={})
    opts[:position] ||= IO::SEEK_END
    if @files[path]
      return # already watching
    end

    # TODO(petef): add since-style support
    if File.directory?(path)
      @logger.warn("Skipping directory #{path}")
      return
    end

    @watch.watch(path, :create, :delete, :modify)

    if File.exists?(path)
      file_action_create(path, opts)
    end
  end # def watch

  def each(&block)
    @watch.each do |path, event|
      method = "file_action_#{event}".to_sym
      if respond_to?(method)
        send(method, path, &block)
      end
    end
  end

  def subscribe(&block)
    loop do
      each(&block)

      sleep(1)
    end
  end # def subscribe

  def file_action_create(path, opts={}, &block)
    if @files[path]
      raise FileWatch::Exception.new("#{path} got create but already open!")
    end

    opts[:position] ||= 0
    begin
      @files[path] = File.new(path, "r")
      if opts[:position] == IO::SEEK_END
        @files[path].sysseek(0, opts[:position])
      else
        @files[path].sysseek(opts[:position])
      end
    rescue Errno::EACCES
      @logger.warn("Error opening #{path}: #{$!}")
    end
  end

  def file_action_delete(path, &block)
    file_action_modify(path, &block)  # read what we can from the FD

    if @files[path]
      @files[path].close
      @files.delete(path)
    end
  end

  def file_action_modify(path, &block)
    file_action_create(path) unless @files[path]

    loop do
      begin
        data = @files[path].read_nonblock(4096)
        yield path, data
      rescue Errno::EWOULDBLOCK, Errno::EINTR
        break
      rescue EOFError
        break
      end
    end
  end
end # class FileWatch::Tail
