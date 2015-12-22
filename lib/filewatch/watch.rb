require "logger"
if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
  require "filewatch/winhelper"
end

module FileWatch
  class Watch
    class WatchedFile
      def self.new_initial(path, inode)
        new(path, inode, true)
      end

      def self.new_ongoing(path, inode)
        new(path, inode, false)
      end

      attr_reader :size, :inode
      attr_writer :create_sent, :initial, :timeout_sent

      attr_reader :path

      def initialize(path, inode, initial)
        @path = path
        @size, @create_sent, @timeout_sent = 0, false, false
        @inode, @initial = inode, initial
      end

      def update(stat, inode = nil)
        @size = stat.size
        @inode = inode if inode
      end

      def create_sent?
        @create_sent
      end

      def initial?
        @initial
      end

      def timeout_sent?
        @timeout_sent
      end

      def to_s() inspect; end
    end

    attr_accessor :logger, :close_older, :ignore_older

    public
    def initialize(opts={})
      @iswindows = ((RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) != nil)
      if opts[:logger]
        @logger = opts[:logger]
      else
        @logger = Logger.new(STDERR)
        @logger.level = Logger::INFO
      end
      @watching = []
      @exclude = []
      @files = Hash.new { |h, k| h[k] = WatchedFile.new(k, false, false) }
      @unwatched = Hash.new
      # we need to be threadsafe about the mutation
      # of the above 2 ivars because the public
      # methods each, discover, watch and unwatch
      # can be called from different threads.
      @lock = Mutex.new
      # we need to be threadsafe about the quit mutation
      @quit = false
      @quit_lock = Mutex.new
    end # def initialize

    public
    def exclude(path)
      path.to_a.each { |p| @exclude << p }
    end

    public
    def watch(path)
      synchronized do
        if !@watching.member?(path)
          @watching << path
          _discover_file(path) do |filepath, stat|
            WatchedFile.new_initial(filepath, inode(filepath, stat))
          end
        end
      end
      return true
    end # def watch

    def unwatch(path)
      synchronized do
        result = false
        if @watching.delete(path)
          _globbed_files(path).each do |file|
            deleted = @files.delete(file)
            @unwatched[file] = deleted if deleted
          end
          result = true
        else
          result = @files.delete(path)
          @unwatched[path] = result if result
        end
        return !!result
      end
    end

    public
    def inode(path,stat)
      if @iswindows
        fileId = Winhelper.GetWindowsUniqueFileIdentifier(path)
        inode = [fileId, 0, 0] # dev_* doesn't make sense on Windows
      else
        inode = [stat.ino.to_s, stat.dev_major, stat.dev_minor]
      end
      return inode
    end

    # Calls &block with params [event_type, path]
    # event_type can be one of:
    #   :create_initial - initially present file (so start at end for tail)
    #   :create - file is created (new file after initial globs, start at 0)
    #   :modify - file is modified (size increases)
    #   :delete - file is deleted
    public
    def each(&block)
      synchronized do
        # Send any creates.
        @files.each do |path, watched_file|
          if !watched_file.create_sent?
            if watched_file.initial?
              yield(:create_initial, path)
            else
              yield(:create, path)
            end
            watched_file.create_sent = true
          end
        end

        @files.each do |path, watched_file|
          begin
            stat = File::Stat.new(path)
          rescue Errno::ENOENT
            # file has gone away or we can't read it anymore.
            @files.delete(path)
            @logger.debug? && @logger.debug("#{path}: stat failed (#{$!}), deleting from @files")
            yield(:delete, path)
            next
          end

          if file_closable?(stat, watched_file)
            if !watched_file.timeout_sent?
              @logger.debug? && @logger.debug("#{path}: file expired")
              yield(:timeout, path)
              watched_file.timeout_sent = true
            end
            next
          end

          inode = inode(path,stat)
          old_size = watched_file.size

          if inode != watched_file.inode
            @logger.debug? && @logger.debug("#{path}: old inode was #{watched_file.inode.inspect}, new is #{inode.inspect}")
            yield(:delete, path)
            yield(:create, path)
          elsif stat.size < old_size
            @logger.debug? && @logger.debug("#{path}: file rolled, new size is #{stat.size}, old size #{old_size}")
            yield(:delete, path)
            yield(:create, path)
          elsif stat.size > old_size
            @logger.debug? && @logger.debug("#{path}: file grew, old size #{old_size}, new size #{stat.size}")
            yield(:modify, path)
          end

          watched_file.update(stat, inode)
        end
      end
    end # def each

    public
    def discover
      synchronized do
        @watching.each do |path|
          _discover_file(path) do |filepath, stat|
            WatchedFile.new_ongoing(filepath, inode(filepath, stat))
          end
        end
      end
    end

    public
    def subscribe(stat_interval = 1, discover_interval = 5, &block)
      glob = 0
      reset_quit
      while !quit?
        each(&block)

        glob += 1
        if glob == discover_interval
          discover
          glob = 0
        end

        sleep(stat_interval)
      end
    end # def subscribe

    private
    def file_closable?(stat, watched_file)
      file_can_close?(stat) && watched_file.size == stat.size
    end

    def file_ignorable?(stat)
      return false unless expiry_ignore_enabled?
      # (Time.now - stat.mtime) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all ints instead
      (Time.now.to_i - stat.mtime.to_i) > @ignore_older
    end

    def file_can_close?(stat)
      return false unless expiry_close_enabled?
      # (Time.now - stat.mtime) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all ints instead
      (Time.now.to_i - stat.mtime.to_i) > @close_older
    end

    private
    def _discover_file(path)
      _globbed_files(path).each do |file|
        next if @files.member?(file)
        next if @unwatched.member?(file)
        next unless File.file?(file)

        @logger.debug? && @logger.debug("_discover_file: #{path}: new: #{file} (exclude is #{@exclude.inspect})")

        skip = false
        @exclude.each do |pattern|
          if File.fnmatch?(pattern, File.basename(file))
            @logger.debug? && @logger.debug("_discover_file: #{file}: skipping because it " +
                          "matches exclude #{pattern}")
            skip = true
            break
          end
        end
        next if skip

        stat = File::Stat.new(file)
        # let the caller build the object in its context
        watched_file = yield(file, stat)

        if file_ignorable?(stat)
          msg = "_discover_file: #{file}: skipping because it was last modified more than #{@ignore_older} seconds ago"
          @logger.debug? && @logger.debug(msg)
          # we update the size on discovery here
          # so the existing contents are not read.
          # because, normally, a newly discovered file will
          # have a watched_file size of zero
          watched_file.update(stat)
        end

        @files[file] = watched_file
      end
    end # def _discover_file

    private
    def expiry_close_enabled?
      !@close_older.nil?
    end

    private
    def expiry_ignore_enabled?
      !@ignore_older.nil?
    end

    private
    def _globbed_files(path)
      globbed_dirs = Dir.glob(path)
      @logger.debug? && @logger.debug("_globbed_files: #{path}: glob is: #{globbed_dirs}")
      if globbed_dirs.empty? && File.file?(path)
        globbed_dirs = [path]
        @logger.debug? && @logger.debug("_globbed_files: #{path}: glob is: #{globbed_dirs} because glob did not work")
      end
      # return Enumerator
      globbed_dirs.to_enum
    end

    private
    def synchronized(&block)
      @lock.synchronize { block.call }
    end

    private
    def quit?
      @quit_lock.synchronize { @quit }
    end

    private
    def reset_quit
      @quit_lock.synchronize { @quit = false }
    end

    public
    def quit
      @quit_lock.synchronize { @quit = true }
    end # def quit
  end # class Watch
end # module FileWatch
