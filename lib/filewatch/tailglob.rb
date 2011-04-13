require "filewatch/namespace"
require "filewatch/exception"
require "filewatch/watchglob"
require "logger"

class FileWatch::TailGlob
  attr_accessor :logger

  public
  def initialize
    @watch = FileWatch::WatchGlob.new

    # hash of string path => File
    @files = {}
    @globoptions = {}
    @options = {}

    self.logger = Logger.new(STDERR)
    # hash of string path => action to take on EOF
  end # def initialize

  def logger=(logger)
    @logger = logger
    @watch.logger = logger
  end

  # Watch a path glob.
  #
  # Options is a hash of:
  #   :exclude => array of globs to ignore.
  public
  def tail(glob, options={}, &block)
    what_to_watch = [ :create, :modify, :delete ]

    # Setup a callback specific to tihs tail call for handling
    # new files found; so we can attach options to each new file.
    callback_set_options = lambda do |path| 
      @options[path] = options
    end

    # Save glob options
    @globoptions[glob] = options

    # callbacks can be an array of functions to call.
    callbacks = [ callback_set_options ]
    callbacks << block if block_given?
    @globoptions[glob][:new_follow_callback] = callbacks

    @watch.watch(glob, *what_to_watch) do |path|
      # Save per-path options
       callback_set_options.call(path)
     
      # for each file found by the glob, open it.
      follow_file(path, :end)
    end # @watch.watch
  end # def watch

  private
  def follow_file(path, seek=:end)
    # Don't follow things that aren't files.
    if !File.file?(path) 
      @logger.info "Skipping follow on #{path}, File.file? == false"
      return
    end

    options = @options[path] || {}
    if options.include?(:exclude)
      options[:exclude].each do |exclusion|
        if File.fnmatch?(exclusion, path)
          @logger.info "Skipping #{path.inspect}, matches exclusion #{exclusion.inspect}"
          return
        end
      end
    end

    if options.include?(:new_follow_callback)
      options[:new_follow_callback].each do |callback|
        #puts "Callback: #{callback.inspect}"
        callback.call(path)
      end
    end

    close(path) if @files.include?(path)
    @files[path] = File.new(path, "r")
    
    # TODO(sissel): Support 'since'-like support.
    case seek
      when :end; @files[path].sysseek(0, IO::SEEK_END)
      when :beginning; # nothing
      else
        if seek.is_a?(Numeric)
          # 'seek' could be a number that is an offset from
          # the start of the file. We should seek to that point.
          @files[path].sysseek(seek, IO::SEEK_SET)
        end # seek.is_a?(Numeric)
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
    file = @files[path]
    # Check if this path is in the exclude list.
    # TODO(sissel): Is this check sufficient?
    if file.nil?
      @logger.info "Ignoring modify on '#{path}' - it's probably ignored'"
      return
    end

    # Read until EOF, emitting each chunk read.
    loop do
      begin
        data = file.sysread(4096)
        yield event.name, data
      rescue EOFError
        check_for_truncation_or_deletion(path, event, &block)
        break
      end
    end # loop
  end # def file_action_modify

  protected
  def check_for_truncation_or_deletion(path, event, &block)
    file = @files[path]
    pos = file.sysseek(0, IO::SEEK_CUR)
    #puts "EOF(#{path}), pos: #{pos}"

    # Truncation is determined by comparing the current read position in the
    # file against the size of the file. If the file shrank, than we should
    # assume truncation and seek to the beginning.
    begin
      stat = file.stat
      #p stat.size => pos
      if stat.size < pos
        # Truncated. Seek to beginning and read.
        file.sysseek(0, IO::SEEK_SET)
        file_action_modify(path, event, &block)
      end
    rescue Errno::ENOENT
      # File was deleted or renamed. Stop following it.
      close(path)
    end
  end # def follow_file

  protected
  def reopen(path)
    close(path)
    follow_file(path, :beginning)
  end # def reopen

  protected
  def close(path)
    @files[path].close rescue nil
    @files.delete(path)
    return nil
  end

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
    close(path)
    # ignore
  end

  def file_action_delete_self(path, event, &block)
    close(path)
    # ignore
    #p :delete_self => path
  end

  # Returns true if we are currently following the file at the given path.
  public
  def following?(path)
    return @files.include?(path)
  end # def following
end # class FileWatch::Tail
