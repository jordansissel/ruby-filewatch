require "filewatch/namespace"
require "filewatch/exception"
require "filewatch/watchglob"

class FileWatch::TailGlob

  public
  def initialize
    @watch = FileWatch::WatchGlob.new

    # hash of string path => File
    @files = {}

    # hash of string path => action to take on EOF
    #@eof_actions = {}
  end # def initialize

  public
  def tail(path)
    what_to_watch = [ :create, :modify, :delete ]
    @watch.watch(path, *what_to_watch) do |path|
      # for each file found by the glob, open it.
      follow_file(path, :end)
    end
  end # def watch

  private
  def follow_file(path, seek=:end)
    # Don't follow things that aren't files.
    if !File.file?(path) 
      puts "Skipping follow on #{path}, File.file? == false"
    end

    @files[path] = File.new(path, "r")
    
    # TODO(sissel): Support 'since'-like support.
    # Always start
    case seek
      when :end; @files[path].sysseek(0, IO::SEEK_END)
      when :beginning; # nothing
      else
        # handle specific positions
    end # case seek
  end # def follow_file

  public
  def subscribe(handler=nil, &block)
    # TODO(sissel): Add handler support.
    @watch.subscribe do |event|
      path = event.name

      event.actions.each do |action|
        method = "file_action_#{action}".to_sym
        if respond_to?(method)
          send(method, path, event, &block)
        else
          $stderr.puts "Unsupported method #{self.class.name}##{method}"
        end
      end
    end # @watch.subscribe
  end # def subscribe

  protected
  def file_action_modify(path, event, &block)
    loop do
      begin
        data = @files[path].sysread(4096)
        yield event.name, data
      rescue EOFError
        #case @eof_actions[path]
          #when :reopen
            #puts "Reopening #{path} due to eof and new file"
            #reopen(path)
        #end

        break
      end
    end
  end

  protected
  def reopen(path)
    @files[path].close rescue nil
    @files.delete(path)
    follow_file(path, :beginning)
  end # def reopen

  protected
  def file_action_create(path, event, &block)
    if following?(path)
      # TODO(sissel): If we are watching this file already, schedule it to be
      # opened the next time we hit EOF on the current file descriptor for the
      # same file. Maybe? Or is reopening now fine?
      #
      reopen(path)

      # Schedule a reopen at EOF
      #@eof_actions[path] = :reopen
    else
      # If we are not yet watching this file, watch it.
      follow_file(path, :beginning)

      # Then read all of the data so far since this is a new file.
      file_action_modify(path, event, &block)
    end
  end # def file_action_create

  def file_action_delete(path, event, &block)
    # ignore
  end

  def file_action_delete_self(path, event, &block)
    p :delete_self => path
  end

  # Returns true if we are currently following the file at the given path.
  public
  def following?(path)
    return @files.include?(path)
  end # def following
end # class FileWatch::Tail
