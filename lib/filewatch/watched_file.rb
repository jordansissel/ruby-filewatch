require "filewatch/buftok"

module FileWatch
  class WatchedFile
    def self.new_initial(path, inode, stat = nil)
      new(path, inode, stat, true)
    end

    def self.new_ongoing(path, inode, stat = nil)
      new(path, inode, stat, false)
    end

    def self.close_older=(value)
      @close_older = value
    end

    def self.ignore_older=(value)
      @ignore_older = value
    end

    def self.delimiter=(value)
      @delimiter = value
    end

    def self.delimiter
      @delimiter
    end

    def self.expiry_close_enabled?
      !@close_older.nil?
    end

    def self.expiry_ignore_enabled?
      !@ignore_older.nil?
    end

    def self.close_older
      @close_older
    end

    def self.ignore_older
      @ignore_older
    end

    attr_reader :size, :inode, :state, :file, :buffer
    attr_reader :path, :filestat, :ignored_size, :accessed_at

    def initialize(path, inode, stat, initial)
      @path = path
      @ignored_size = @size = 0
      @inode = inode
      @initial = initial
      @state = :watched
      if (@filestat = stat).nil? && !@inode.nil?
        restat
      end
      set_accessed_at
    end

    def set_accessed_at
      @accessed_at = Time.now.to_i
    end

    def initial?
      @initial
    end

    def size_changed?
      filestat.size != size
    end

    def inode_changed?(value)
      self.inode != value
    end

    def file_add_opened(rubyfile)
      @file = rubyfile
      @buffer = FileWatch::BufferedTokenizer.new(self.class.delimiter || "\n")
    end

    def file_close
      return if @file.nil? || @file.closed?
      @file.close
      @file = nil
    end

    def file_seek(amount, whence = IO::SEEK_SET)
      @file.sysseek(amount, whence)
    end

    def file_read(amount)
      set_accessed_at
      @file.sysread(amount)
    end

    def file_open?
      !@file.nil? && !@file.closed?
    end

    def buffer_extract(data)
      @buffer.extract(data)
    end

    def update_inode(_inode)
      @inode = _inode
    end

    def update_size
      @size = @filestat.size
    end

    def activate
      @state = :active
    end

    def ignore
      @state = :ignored
      @ignored_size = @size = @filestat.size
    end

    def close
      @state = :closed
    end

    def watch
      @state = :watched
    end

    def unwatch
      @state = :unwatched
    end

    def active?
      @state == :active
    end

    def ignored?
      @state == :ignored
    end

    def closed?
      @state == :closed
    end

    def watched?
      @state == :watched
    end

    def unwatched?
      @state == :unwatched
    end

    def restat
      @filestat = File::Stat.new(path)
    end

    def file_closable?
      file_can_close? && !size_changed?
    end

    def file_ignorable?
      return false unless self.class.expiry_ignore_enabled?
      # (Time.now - stat.mtime) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all ints instead
      (Time.now.to_i - filestat.mtime.to_i) > self.class.ignore_older
    end

    def file_can_close?
      return false unless self.class.expiry_close_enabled?
      # (Time.now - @open_at) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all ints instead
      # (Time.now.to_i - filestat.mtime.to_i) > self.class.close_older
      (Time.now.to_i - @accessed_at) > self.class.close_older
    end

    def to_s() inspect; end
  end
end
