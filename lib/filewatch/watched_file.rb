require "filewatch/buftok"
require "digest/md5"

module FileWatch
  class WatchedFile
    FakeStat = Struct.new(:size, :ctime, :mtime)

    def self.new_initial(path, inode, stat)
      new(path, inode, stat, true)
    end

    def self.new_ongoing(path, inode, stat)
      new(path, inode, stat, false)
    end

    def self.deserialize(line)
      return if line.empty?
      parts = line.split(' ')
      if parts.size > 4
        ino, dj, dn, rb, typ, ca, ma, lss, path, st, brd, sth = parts
        return if typ != 'W'
        return unless File.exist?(path)
      else
        # its a legacy sincedb record
        ino, dj, dn, rb = parts
        typ, ca, ma, lss, path, st, sth, brd = "W", 0.0, 0.0, 0, "unknown", "watched", nil, nil
      end
      stat = FakeStat.new(lss.to_i, Float(ca), Float(ma))
      instance = new_ongoing(path, [ino, 0, 0], stat)
      instance.set_state(st.to_sym)
      instance.state_history.clear
      instance.state_history.replace(sth.split(",").map(&:to_sym)) if sth
      instance.add_bytes_read_digest(brd) if brd
      instance.update_bytes_read(rb.to_i)
      instance
    end

    attr_reader :bytes_read, :inode, :state, :file, :buffer, :state_history
    attr_reader :path, :filestat, :accessed_at, :created_at, :modified_at
    attr_reader :storage_key, :last_stat_size, :bytes_read_digest
    attr_accessor :close_older, :ignore_older, :delimiter

    def delimiter
      @delimiter
    end

    def initialize(path, inode, stat, initial)
      @path = path
      @bytes_read = 0
      @inode = inode
      @initial = initial
      @state_history = []
      @state = :watched
      set_stat(stat)
      set_storage_key
      set_accessed_at
    end

    def init_vars(delim, ignore_o, close_o)
      @delimiter = delim
      @ignore_older = ignore_o
      @close_older = close_o
      self
    end

    def add_bytes_read_digest(hd)
      @bytes_read_digest = hd
    end

    # subclass may override
    def compute_storage_key
      "#{raw_inode}|#{path}"
    end

    def set_accessed_at
      @accessed_at = Time.now.to_f
    end

    def set_storage_key
      @storage_key = compute_storage_key
    end

    def initial?
      @initial
    end

    def size_changed?
      @last_stat_size != bytes_read
    end

    def inode_changed?(value)
      self.inode != value
    end

    def file_add_opened(rubyfile)
      @file = rubyfile
      @buffer = FileWatch::BufferedTokenizer.new(delimiter || "\n")
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

    def update_bytes_read(total_bytes_read)
      return if total_bytes_read.nil?
      @bytes_read = total_bytes_read
    end

    def update_inode(_inode)
      @inode = _inode
      set_storage_key
      @inode
    end

    def update_path(_path)
      @path = _path
      set_storage_key
      @path
    end

    def update_stat(st)
      set_stat(st)
    end

    def activate
      set_state :active
    end

    def ignore
      set_state :ignored
      @bytes_read = @filestat.size
    end

    def close
      set_state :closed
    end

    def watch
      set_state :watched
    end

    def unwatch
      set_state :unwatched
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

    def expiry_close_enabled?
      !@close_older.nil?
    end

    def expiry_ignore_enabled?
      !@ignore_older.nil?
    end

    def restat
      set_stat(File::Stat.new(path))
    end

    def set_state(value)
      @state_history << @state
      @state = value
    end

    def state_history_any?(*previous)
      (@state_history & previous).any?
    end

    def file_closable?
      file_can_close? && !size_changed?
    end

    def file_ignorable?
      return false unless expiry_ignore_enabled?
      # (Time.now - stat.mtime) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all floats upfront
      (Time.now.to_f - @modified_at) > ignore_older
    end

    def file_can_close?
      return false unless expiry_close_enabled?
      (Time.now.to_f - @accessed_at) > close_older
    end

    def to_s() inspect; end

    def raw_inode
      @raw_inode ||= @inode.first
    end

    def content_equal?(other)
      # use as last resort to compare file content
      full_digest == other.full_digest
    end

    def equivalent?(other)
      @created_at == other.created_at &&
        @last_stat_size == other.last_stat_size
    end

    def serialize
      "#{raw_inode} 0 0 #{bytes_read} W #{created_at} #{modified_at} #{last_stat_size} #{path} #{state} #{read_bytes_digest} #{state_history.join(',')}"
    end

    def content_read_equal?(other)
      other_digest = other.read_bytes_digest(bytes_read)
      return false if bytes_read_digest.nil? || other_digest.nil?
      bytes_read_digest == other_digest
    end

    def full_digest
      return unless File.exist?(path)
      Digest::MD5.file(path).hexdigest
    end

    def read_bytes_digest(position = @bytes_read)
      return if position.zero?
      if position < last_stat_size
        return unless File.exist?(path)
        Digest::MD5.hexdigest(File.open(path){|f| f.read(position)})
      else
        full_digest
      end
    end

    private

    def set_stat(stat)
      @last_stat_size = stat.size
      @created_at = stat.ctime.to_f
      @modified_at = stat.mtime.to_f
      @filestat = stat
    end
  end
end
