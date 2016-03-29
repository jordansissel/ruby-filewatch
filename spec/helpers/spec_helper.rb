require 'stud/temporary'
require "rspec_sequencing"
require "fileutils"
require "filewatch/boot_setup"

def formatted_puts(text)
  cfg = RSpec.configuration
  return unless cfg.formatters.first.is_a?(
        RSpec::Core::Formatters::DocumentationFormatter)
  txt = cfg.format_docstrings_block.call(text)
  cfg.output_stream.puts "    #{txt}"
end

unless RSpec::Matchers.method_defined?(:receive_call_and_args)
  RSpec::Matchers.define(:receive_call_and_args) do |m, args|
    match do |actual|
      actual.trace_for(m) == args
     end

    failure_message do
      "Expecting method #{m} to receive: #{args} but got: #{actual.trace_for(m)}"
    end
  end
end

module FileWatch
  def self.extract_pos(sincedb_record)
    k, v = SinceDb.parse_line(sincedb_record)
    v.position
  end

  def self.sincedb_v2_regex(pos = nil)
    %r|\d{18,22},\d{1,10},\d{1,6} #{pos ||"\\d{1,10}"} \d+\.\d+(\s\d{18,22},\d{1,10},\d{1,6})?\s?|
  end

  def self.path_to_fixture(file_name)
    File.expand_path("../fixtures/#{file_name}", File.dirname(__FILE__))
  end

  def self.make_file_older(path, seconds)
    time = Time.now.to_f - seconds
    File.utime(time, time, path)
  end

  def self.songs1_short
    songs1.slice(0, 138)
  end
  def self.songs2_short
    songs2.slice(0, 179)
  end

  def self.songs1
    <<-SONGS
Northern Hemisphere,East of Eden,Mercator Projected,1968,Progresive Rock,1
Isadora,East of Eden,Mercator Projected,1968,Progresive Rock,2
Waterways,East of Eden,Mercator Projected,1968,Progresive Rock,3
Centaur Woman,East of Eden,Mercator Projected,1968,Progresive Rock,4
Bathers,East of Eden,Mercator Projected,1968,Progresive Rock,5
Communion,East of Eden,Mercator Projected,1968,Progresive Rock,6
Moth,East of Eden,Mercator Projected,1968,Progresive Rock,7
In the Stable of the Sphinx,East of Eden,Mercator Projected,1968,Progresive Rock,8
SONGS
  end

  def self.songs2
    <<-SONGS
"On the Other Side Pt. I","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal",1
"No Familiar Faces","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal"2
"Prolong a Stay","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal",3
"Blueprints","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal",4
"If Not Here, Where?","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal",5
"The Storm Arrives","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal",6
"See This Through","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal",7
"On The Other Side Pt. II","Amoral","Fallen Leaves & Dead Sparrows",2014,"Progresive Metal",8
SONGS
  end

  def self.sdb_rec_for_45k_file
    "8864371933797704358,0,255 45003 1460010783.808 1946650054937152164,37002,255\n"
  end

  def self.lines_for_45K_file
    ["a" * 12000, "b" * 25000, "c" * 8000]
  end

  def self.v1_sdb_rec_for_big1_file
    path = path_to_fixture("big1.txt")
    stat = File::Stat.new(path)
    inode = WatchedFile.inode(path, stat)
    k = SincedbKey1.new(*inode)
    "#{k} #{stat.size}\n"
  end

  class Watch4Test < Watch
    attr_reader :files
  end

  class TracerBase
    def initialize() @tracer = []; end

    def trace_for(symbol)
      params = @tracer.map {|k,v| k == symbol ? v : nil}.compact
      params.empty? ? false : params
    end

    def clear()
      @tracer.clear()
    end
  end

  class FileLogTracer < TracerBase
    def warn(*args) @tracer.push [:warn, args]; end
    def error(*args) @tracer.push [:error, args]; end
    def debug(*args) @tracer.push [:debug, args]; end
    def info(*args) @tracer.push [:info, args]; end

    def info?() true; end
    def debug?() true; end
    def warn?() true; end
    def error?() true; end
  end

  module NullCallable
    def self.call() end
  end

  class TailObserver
    class Listener

      def self.count
        @counter = @counter.succ
      end

      def self.reset
        @counter = 0
      end

      attr_reader :path, :lines, :calls, :accepts

      def initialize(path)
        @path = path
        @accepts = []
        @lines = []
        @calls = []
      end

      def accept(line)
        @lines << line
        @calls << :accept
        @accepts << self.class.count
      end

      def deleted()
        @calls << :delete
      end

      def created()
        @calls << :create
      end

      def error()
        @calls << :error
      end

      def eof()
        @calls << :eof
      end

      def timed_out()
        @calls << :timed_out
      end
    end

    attr_reader :listeners

    def initialize
      Listener.reset
      @listeners = Hash.new {|hash, key| hash[key] = Listener.new(key) }
    end

    def listener_for(path)
      @listeners[path]
    end

    def clear() @listeners.clear; end
  end
end
