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
  def watch(path, *what_to_watch)
    @watch.watch(path, *what_to_watch)

    if File.file?(path)
      @files[path] = File.new(path, "r")
      
      # TODO(sissel): Support 'since'-like support.
      # Always start at the end of the file, this may change in the future.
      @files[path].sysseek(0, IO::SEEK_END)
    end
  end # def watch

  def subscribe(handler=nil, &block)
    @watch.subscribe(nil) do |event|
      path = event.name
      if @files.include?(path)
        file = @files[path]
        event.actions.each do |action|
          method = "file_action_#{action}".to_sym
          if respond_to?(method)
            send(method, file, event, &block)
          else
            $stderr.puts "Unsupported method #{self.class.name}##{method}"
          end
        end
      else
        $stderr.puts "Event on unwatched file: #{event}"
      end
    end
  end # def subscribe

  def file_action_modify(file, event)
    loop do
      begin
        data = file.sysread(4096)
        yield event.name, data
      rescue EOFError
        break
      end
    end
  end

end # class FileWatch::Tail
