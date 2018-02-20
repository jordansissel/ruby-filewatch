# encoding: utf-8
require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SincedbValue
    EXP_SECONDS = SDB_EXPIRES_DAYS * 24 * 3600
    attr_reader :last_seen_at, :watched_file

    def initialize(position, last_seen_at = nil, second_fp = nil, watched_file = nil)
      @position = position # this is the value read from disk
      @last_seen_at = last_seen_at
      @second_fp = second_fp # from sincedb serializer, must be a struct or nil
      @watched_file = watched_file
      upd_expiry if @last_seen_at.nil? || @last_seen_at.zero?
    end

    def position
      # either the value from disk or the current wf position
      if @watched_file.nil?
        @position
      else
        @watched_file.bytes_read
      end
    end

    def upd_position(pos)
      upd_expiry
      if @watched_file.nil?
        @position = pos
      else
        @watched_file.update_bytes_read(pos)
      end
    end

    def inc_position(pos)
      upd_expiry
      if watched_file.nil?
        @position += pos
      else
        @watched_file.increment_bytes_read(pos)
      end
    end

    def set_watched_file(wf)
      upd_expiry
      @watched_file = wf
    end

    def upd_expiry
      @last_seen_at = Time.now.to_f
    end

    def to_s
      "#{position} #{last_seen_at}".tap do |s|
        s.concat(" #{second_fingerprint}") if !second_fingerprint.nil?
      end
    end

    def second_fingerprint
      if @watched_file.nil? || @watched_file.last_fingerprint.nil?
        return @second_fp
      else
        @watched_file.last_fingerprint.to_struct
      end
    end

    def unset_watched_file
      # cache the position and second_fingerprint this value last had
      return if @watched_file.nil?
      wf = @watched_file
      @watched_file = nil
      @position = wf.bytes_read
      return if wf.last_fingerprint.nil?
      @second_fp = wf.last_fingerprint.to_struct
    end
  end
end
