require "rubygems"
require "filewatch/exception"
require "filewatch/namespace"

module FileWatch; class Stat
  include Enumerable

  public
  def self.can_watch?(filestat)
    # TODO(petef): implement.
    return true
  end # def self.can_watch?

  public
  def initialize
    @watches = {}
  end # def initialize

  # Add a watch.
  # - path is a string file path
  # - what_to_watch is a set of:
  #  :modify
  #  :create
  #  :delete
  #  TODO(petef): support :access, :attrib
  public
  def watch(path, *what_to_watch)
    if @watches.member?(path)
      raise FileWatch::Exception.new("already watching #{path}")
    end

    @watches[path] = {
      :inode => nil,
      :size => 0,
      :exists => File.exists?(path),
      :watch => what_to_watch,
    }
  end # def watch

  # For Enumerable support
  #
  # Yields one FileWatch::Stat::Event per iteration. If there are no more events
  # at the this time, then this method will end.
  public
  def each(&block)
    @watches.each do |path, state|
      s = nil
      begin
        s = File::Stat.new(path)
      rescue Errno::ENOENT
        # ok
      end

      if !s
        if @watches[path][:exists]
          # delete event
          puts "filewatch: #{path}: used to exist, deleted" if $DEBUG
          @watches[path][:exists] = false
          yield(path, :delete)
        end
        return
      elsif !@watches[path][:exists]
        # create event
        puts "filewatch: #{path}: used to not exist, created" if $DEBUG
        @watches[path][:exists] = true
        yield(path, :create)
        return
      end

      state[:inode] ||= [s.ino, s.dev_major, s.dev_minor]

      events = []

      # If the inode numbers have changed, or the size is less than it was
      # last time, send a delete+create event (log was rolled)
      if state[:inode] != [s.ino, s.dev_major, s.dev_minor]
        puts "filewatch: #{path}: inode changed" if $DEBUG
        events << :delete
        events << :create
        if s.size > 0
          puts "filewatch: #{path}: size is >0 after inode change" if $DEBUG
          events << :modify
        end
      elsif s.size < state[:size]
        puts "filewatch: #{path}: inode is the same, size reset" if $DEBUG
        events << :delete
        events << :create
        if s.size > 0
          puts "filewatch: #{path}: size is >0 after size reset" if $DEBUG
          events << :modify
        end
      elsif s.size > state[:size]
        puts "filewatch: #{path} size grew" if $DEBUG
        events << :modify
      end

      notify_events = events.select { |e| state[:watch].member?(e) }
      notify_events.each { |event| yield(path, event) }

      @watches[path][:size] = s.size
      @watches[path][:inode] = [s.ino, s.dev_major, s.dev_minor]
    end # @watches.each
  end # def each

  public
  def subscribe(handler=nil, &block)
    loop do
      sleep(1)

      each(&block)
    end
  end # def subscribe
end; end # class FileWatch::Stat
