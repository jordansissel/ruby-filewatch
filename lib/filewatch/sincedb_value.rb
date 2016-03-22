require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SincedbValue
    EXP_SECONDS = SDB_EXPIRES_DAYS * 24 * 3600
    attr_reader :position, :expires, :watched_file

    def initialize(position, second_fp = nil, expires = nil, watched_file = nil)
      @position = position
      @second_fp = second_fp
      @expires = expires
      @watched_file = watched_file
      upd_expiry if @expires.nil?
    end

    def upd_position(pos)
      upd_expiry
      @position = pos
      @watched_file.update_bytes_read(@position) if !@watched_file.nil?
    end

    def inc_position(pos)
      upd_expiry
      @position += pos
      @watched_file.update_bytes_read(@position) if !@watched_file.nil?
    end

    def upd_watched_file(wf)
      @watched_file = wf
    end

    def upd_expiry
      @expires = new_expires
    end

    def

    private

    def new_expires
      Time.now.to_f + EXP_SECONDS
    end
  end
end
