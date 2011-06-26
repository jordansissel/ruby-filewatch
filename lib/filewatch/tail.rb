require "filewatch/watch"
require "filewatch/namespace"

class FileWatch::Tail
  # This class exists to wrap inotify, kqueue, periodic polling, etc,
  # to provide you with a way to watch files and directories.
  #
  # For now, it only supports inotify.
  def initialize
    @watch = FileWatch::Watch.new
    @files = {}
  end

  public
  def watch(path)
    @watch.watch(path, :create, :delete, :modify)

    # TODO(petef): add since-style support
    if File.exists?(path)
      @files[path] = File.new(path, "r")
      @files[path].sysseek(0, IO::SEEK_END)
    end
  end # def watch

  def subscribe(handler=nil, &block)
    @watch.subscribe(nil) do |event|
      path = event.name
      event.actions.each do |action|
        # call method 'file_action_<action>' like 'file_action_modify'
        method = "file_action_#{action}".to_sym
        if respond_to?(method)
          send(method, path, event, &block)
        end
      end
    end # @watch.subscribe
  end # def subscribe

  def file_action_create(path, event, &block)
    if @files[path]
      raise FileWatch::Exception.new("#{path} got create but already open!")
    end

    @files[path] = File.new(path, "r")
  end

  def file_action_delete(path, event, &block)
    file_action_modify(path, event, &block)  # read what we can from the FD

    if @files[path]
      @files[path].close
      @files.delete(path)
    end
  end

  def file_action_modify(path, event, &block)
    if !@files[path]
      @files[path] = File.new(path, "r")
    end

    loop do
      begin
        data = @files[path].sysread(4096)
        yield path, data
      rescue EOFError
        break
      end
    end
  end
end # class FileWatch::Tail
