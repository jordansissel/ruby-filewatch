require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SincedbValue
    EXP_SECONDS = SDB_EXPIRES_DAYS * 24 * 3600
    attr_reader :position, :expires, :watched_file

    def initialize(position, expires = nil, second_fp = nil, watched_file = nil)
      @position = position
      @expires = expires
      @second_fp = second_fp # from sincedb file read
      @watched_file = watched_file
      upd_expiry if @expires.nil? || @expires.zero?
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
      upd_expiry
      @watched_file = wf
    end

    def upd_expiry
      @expires = new_expires
    end

    def to_s
      "#{@position} #{@expires}".tap do |s|
        s.concat(" #{second_fingerprint.join(',')}") if !second_fingerprint.nil?
      end
    end

    def second_fingerprint
      if @watched_file.nil?
        return @second_fp
      elsif !@watched_file.last_fingerprint.nil?
        @watched_file.last_fingerprint.to_a
      end
    end

    def clear_watched_file
      @watched_file = nil
    end

    private

    def new_expires
      Time.now.to_f + EXP_SECONDS
    end
  end
end
