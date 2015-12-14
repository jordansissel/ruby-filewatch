require 'filewatch/tail'
require 'stud/temporary'

class TailObserver
  class Listener
    attr_reader :path, :lines, :calls

    def initialize(path)
      @path = path
      @lines = []
      @calls = []
    end

    def accept(line)
      @lines << line
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
    @listeners = Hash.new {|hash, key| hash[key] = Listener.new(key) }
  end

  def listener_for(path)
    @listeners[path]
  end

  def clear() @listeners.clear; end
end

describe FileWatch::Tail do
  let(:observer) { TailObserver.new }
  let(:file_path) { f = Stud::Temporary.pathname }
  let(:sincedb_path) { Stud::Temporary.pathname }
  let(:quit_sleep) { 0.1 }

  before do
    Thread.new {sleep quit_sleep; subject.quit }
  end

  context "when watching a new file" do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

    before :each do
      subject.tail(file_path)
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
    end

    it "reads new lines off the file" do
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
      expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof])
    end
  end

  context "when watching a file" do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

    before :each do
      File.open(file_path, "wb") { |file|  file.write("lineA\nlineB\n") }
      subject.tail(file_path)
    end

    it "reads new lines off the file" do
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["lineA", "lineB"])
      expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof])
    end

  end

  context "when watching a CRLF file" do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path,
                                  :start_new_files_at => :beginning,
                                  :delimiter => "\r\n") }

    before :each do
      File.open(file_path, "wb") { |file|  file.write("lineC\r\nlineD\r\n") }
      subject.tail(file_path)
    end

    it "reads new lines off the file" do
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["lineC", "lineD"])
      expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof])
    end
  end

  context "when a file is deleted" do
    let(:quit_sleep) { 2 }

    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0.25) }

    before :each do
      File.open(file_path, "w") { |file|  file.write("line1\nline2\n") }
      subject.tail(file_path)
      Thread.new { sleep(quit_sleep - 1); File.unlink file_path }
    end

    it "should read the lines and call deleted on listener" do
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
      expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof, :eof, :delete])
    end
  end

  describe "sincedb" do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

    before :each do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.tail(file_path)
    end

    context "when reading a new file" do
      it "updates sincedb after subscribe" do
        subject.subscribe(observer)
        stat = File::Stat.new(file_path)
        sincedb_id = subject.sincedb_record_uid(file_path,stat).join(' ')
        expect(File.read(sincedb_path)).to eq("#{sincedb_id} #{stat.size}\n")
      end
    end

    context "when restarting tail" do
      before :each do
        subject.subscribe(observer)
        sleep 0.2 # wait for tail.quit
        subject.tail(file_path) # re-tail file
        # we remove previous because normally the observer would not store the transient data
        observer.clear
        File.open(file_path, "ab") { |file| file.write("line3\nline4\n") }
        Thread.new(subject) { sleep 0.1; subject.quit }
      end

      it "picks off from where it stopped" do
        expect { subject.subscribe(observer) }.not_to raise_error
        expect(observer.listeners[file_path].lines).to eq(["line3", "line4"])
        expect(observer.listeners[file_path].calls).to eq([:eof])
      end

      it "updates on tail.quit" do
        subject.subscribe(observer)
        stat = File::Stat.new(file_path)
        sincedb_id = subject.sincedb_record_uid(file_path,stat).join(' ')
        expect(File.read(sincedb_path)).to eq("#{sincedb_id} #{stat.size}\n")
      end
    end
  end

  context "ingesting files bigger than 32k" do
    let(:lineA) { "a" * 12000 }
    let(:lineB) { "b" * 25000 }
    let(:lineC) { "c" * 8000 }
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning) }

    before :each do
      IO.write(file_path, "#{lineA}\n#{lineB}\n#{lineC}\n")
      subject.tail(file_path)
    end

    it "should read all the lines entirely" do
      subject.subscribe(observer)
      expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof])
      expect(observer.listeners[file_path].lines).to eq([lineA, lineB, lineC])
    end
  end

  context "when watching a directory" do

    let(:directory) { Stud::Temporary.directory }
    let(:file_path) { File.join(directory, "1.log") }
    let(:position) { :beginning }

    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => position, :stat_interval => 0) }

    before :each do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.tail(File.join(directory, "*"))
    end

    after :each do
      FileUtils.rm_rf(directory)
    end

    it "reads new lines off the file" do
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
      expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof])
    end

    context "when a file is renamed" do
      let(:quit_sleep) { 1 }

      it "should not re-read the file" do
        subject.subscribe(observer)
        before_lines = observer.listeners[file_path].lines.dup
        before_calls = observer.listeners[file_path].calls.dup
        File.rename(file_path, file_path + ".bak")
        expect(observer.listeners[file_path].lines).to eq(before_lines)
        expect(observer.listeners[file_path].calls).to eq(before_calls)
      end
    end
  end

  if RbConfig::CONFIG['host_os'] !~ /mswin|mingw|cygwin/
    context "when quiting" do
      let(:quit_sleep) { 0.75 }

      subject do
        FileWatch::Tail.new_observing(
          :sincedb_path => sincedb_path,
          :start_new_files_at => :beginning,
          :stat_interval => 0.1)
      end

      before :each do
        subject.tail(file_path)
        File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      end

      it "closes the file handle" do
        subject.subscribe(observer)
        expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
        expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof])
        lsof = `lsof -p #{Process.pid} | grep #{file_path}`
        expect(lsof).to be_empty
      end
    end

    context "when ignore_after is set" do
      let(:quit_sleep) { 3.5 }

      subject do
        FileWatch::Tail.new_observing(
          :sincedb_path => sincedb_path,
          :start_new_files_at => :beginning,
          :stat_interval => 0.1,
          :ignore_after => 2)
      end

      before :each do
        subject.tail(file_path)
        File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      end

      it "closes the file handle" do
        subject.subscribe(observer)
        expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
        expect(observer.listeners[file_path].calls).to eq([:create, :eof, :eof, :timed_out])
        lsof = `lsof -p #{Process.pid} | grep #{file_path}`
        expect(lsof).to be_empty
      end
    end
  end
end
