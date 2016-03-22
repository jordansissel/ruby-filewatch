require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SinceDbUpgrader
    def initialize(discoverer, opts, loggr)
      @old_sincedb = SinceDb.new(opts, loggr)
      @new_sincedb = SinceDbV2.new(opts, loggr)
      @discoverer = discoverer
      @path = @old_sincedb.path
      @sincedb_version_from_config = opts.fetch(:sincedb_version, 1)
    end

    def opened_sincedb
      if use_older?
        use_older
      elsif upgradable?
        do_upgrade
      else
        use_newer
      end
    end

    private

    def use_newer
      @new_sincedb.open
      @new_sincedb
    end

    def use_older
      @old_sincedb.open
      @old_sincedb
    end

    def use_older?
      @sincedb_version_from_config == 1
    end

    def do_upgrade
      @old_sincedb.open
      @discoverer.discover
      @discoverer.watched_files.each do |wf|
        if @old_sincedb.member?(wf)
          pos = @old_sincedb.last_read(wf)
          @new_sincedb.store_last_read(wf, pos)
        else
          @new_sincedb.store_last_read(wf, 0)
        end
      end
      @old_sincedb.clear
      @new_sincedb.write("upgraded")
      @new_sincedb
    end

    def upgradable?
      return false if !File.exist?(@path)
      first_line = File.open(@path){|f| f.gets("\n")}
      @old_sincedb.version_match?(first_line)
    end
  end
end
