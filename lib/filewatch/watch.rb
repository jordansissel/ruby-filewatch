require "logger"
if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
  require "filewatch/winhelper"
end

module FileWatch
  class Watch
    attr_accessor :logger

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
      @files = Hash.new { |h, k| h[k] = Hash.new }
      @unwatched = Hash.new
      # we need to be threadsafe about the mutation
      # of the above 2 ivars because the public
      # methods each, discover, watch and unwatch
      # can be called from different threads.
      @lock = Mutex.new
    end # def initialize

    public
    def logger=(logger)
      @logger = logger
    end

    public
    def exclude(path)
      path.to_a.each { |p| @exclude << p }
    end

    public
    def watch(path)
      synchronized do
        if !@watching.member?(path)
          @watching << path
          _discover_file(path, true)
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
        @files.keys.each do |path|
          if ! @files[path][:create_sent]
            if @files[path][:initial]
              yield(:create_initial, path)
            else
              yield(:create, path)
            end
            @files[path][:create_sent] = true
          end
        end

        @files.keys.each do |path|
          begin
            stat = File::Stat.new(path)
          rescue Errno::ENOENT
            # file has gone away or we can't read it anymore.
            @files.delete(path)
            @logger.debug? && @logger.debug("#{path}: stat failed (#{$!}), deleting from @files")
            yield(:delete, path)
            next
          end

          inode = inode(path,stat)
          if inode != @files[path][:inode]
            @logger.debug? && @logger.debug("#{path}: old inode was #{@files[path][:inode].inspect}, new is #{inode.inspect}")
            yield(:delete, path)
            yield(:create, path)
          elsif stat.size < @files[path][:size]
            @logger.debug? && @logger.debug("#{path}: file rolled, new size is #{stat.size}, old size #{@files[path][:size]}")
            yield(:delete, path)
            yield(:create, path)
          elsif stat.size > @files[path][:size]
            @logger.debug? && @logger.debug("#{path}: file grew, old size #{@files[path][:size]}, new size #{stat.size}")
            yield(:modify, path)
          end

          @files[path][:size] = stat.size
          @files[path][:inode] = inode
        end # @files.keys.each
      end
    end # def each

    public
    def discover
      synchronized do
        @watching.each do |path|
          _discover_file(path)
        end
      end
    end

    public
    def subscribe(stat_interval = 1, discover_interval = 5, &block)
      glob = 0
      @quit = false
      while !@quit
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
    def _discover_file(path, initial=false)
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
        @files[file] = {
          :size => 0,
          :inode => inode(file,stat),
          :create_sent => false,
          :initial => initial
        }
      end
    end # def _discover_file

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

    public
    def quit
      @quit = true
    end # def quit
  end # class Watch
end # module FileWatch
