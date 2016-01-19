require 'filewatch/tail'
require 'stud/temporary'
require_relative 'spec_helper'

describe FileWatch::Tail do
  before(:all) do
    @thread_abort = Thread.abort_on_exception
    Thread.abort_on_exception = true
  end

  after(:all) do
    Thread.abort_on_exception = @thread_abort
  end

  let(:observer) { FileWatch::TailObserver.new }
  let(:file_path) { f = Stud::Temporary.pathname }
  let(:sincedb_path) { Stud::Temporary.pathname }
  let(:quit_sleep) { 0.1 }
  let(:quit_proc) do
    lambda do
      Thread.new {sleep quit_sleep; subject.quit }
    end
  end

  before do |ex|
    return if ex.metadata[:skip_before]
    quit_proc.call
  end

  after :each do
    FileUtils.rm_rf(file_path)
    FileUtils.rm_rf(sincedb_path)
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
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
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
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
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
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
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
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof, :eof, :delete])
    end
  end

  describe "sincedb", :skip_before do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

    context "when reading a new file" do
      it "updates sincedb after subscribe" do
        RSpec::Sequencing
          .run("create file") do
            File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          end
          .then("begin tailing") do
            subject.tail(file_path)
          end
          .then_after(quit_sleep, "quit tailing") do
            subject.quit
          end
        subject.subscribe(observer)
        stat = File::Stat.new(file_path)
        sincedb_id = FileWatch::Watch.inode(file_path, stat).join(" ")
        expect(File.read(sincedb_path)).to eq("#{sincedb_id} #{stat.size}\n")
      end
    end

    context "when restarting tail" do
      let(:restart_actions) do
        RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          stats << File::Stat.new(file_path)
        end
        .then("begin tailing") do
          subject.tail(file_path)
        end
        .then_after(quit_sleep, "quit tailing") do
          subject.quit
        end
        .then_after(0.45, "begin tailing again") do
          results << File.read(sincedb_path)
          # we remove previous because normally the observer would not store the transient data
          observer.clear
          subject.tail(file_path)
        end
        .then_after(0.45, "write more lines to the file") do
          File.open(file_path, "ab") { |file| file.write("line3\nline4\n") }
          stats << File::Stat.new(file_path)
        end
        .then_after(2.1, "quit tailing") do
          subject.quit
        end
        .then_after(0.25, "read sincedb file") do
          results << File.read(sincedb_path)
        end
      end

      let(:results) { [] }
      let(:stats)   { [] }

      it "picks off from where it stopped" do
        restart_actions.activate
        subject.subscribe(observer)
        expect { subject.subscribe(observer) }.not_to raise_error
        expect(observer.listeners[file_path].lines).to eq(["line3", "line4"])
        expect(observer.listeners[file_path].calls).to eq([:accept, :accept, :eof])
      end

      it "updates on tail.quit" do
        restart_actions.activate
        subject.subscribe(observer)
        subject.subscribe(observer)
        restart_actions.value
        stat = stats.last
        sincedb_id = FileWatch::Watch.inode(file_path, stat).join(" ")
        expect(results.first).to eq("#{sincedb_id} #{stats.first.size}\n")
        expect(results.last).to eq("#{sincedb_id} #{stats.last.size}\n")
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
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :accept, :eof])
      expect(observer.listeners[file_path].lines).to eq([lineA, lineB, lineC])
    end
  end

  context "when watching a directory" do

    let(:directory) { Stud::Temporary.directory }
    let(:file_path) { File.join(directory, "1.log") }
    let(:position) { :beginning }

    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => position, :stat_interval => 0) }

    let(:before_proc) do
      lambda do
        File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        subject.tail(File.join(directory, "*"))
      end
    end

    before :each do |ex|
      return if ex.metadata[:skip_before]
      before_proc.call
    end

    after :each do
      FileUtils.rm_rf(directory)
    end

    it "reads new lines off the file" do
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
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

    context "when a file that was modified more than 2 seconds ago is present" do
      let(:before_proc) { FileWatch::NullCallable }
      let(:quit_proc)   { FileWatch::NullCallable }

      subject { FileWatch::Tail.new_observing(
        :sincedb_path => sincedb_path, :start_new_files_at => position,
        :stat_interval => 0.1, :ignore_older => 2) }

      it "the file is ignored" do
        RSpec::Sequencing
          .run("create file") do
            File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          end
          .then_after(3.1, "begin tailing") do
            subject.tail(File.join(directory, "*"))
          end
          .then_after(1.55, "quit") do
            subject.quit
          end
        subject.subscribe(observer)
        expect(observer.listeners[file_path].lines).to eq([])
        expect(observer.listeners[file_path].calls).to eq([])
      end

      context "and then it is written to" do
        it "reads only the new lines off the file" do
          RSpec::Sequencing
          .run("create file") do
            File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          end
          .then_after(3.1, "begin tailing, after allowing file to age") do
            subject.tail(File.join(directory, "*"))
          end.then("write more lines") do
            File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
          end.then_after(0.75, "quit") do
            subject.quit
          end
          subject.subscribe(observer)
          expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
          expect(observer.listeners[file_path].lines).to eq(["line3", "line4"])
        end
      end
    end
  end

  if RbConfig::CONFIG['host_os'] !~ /mswin|mingw|cygwin/
    describe "open or closed file handling" do
      let(:lsof_before_quit) { [] }
      let(:quit_proc) do
        lambda do
          Thread.new do
            sleep quit_sleep
            lsof_before_quit.push `lsof -p #{Process.pid} | grep #{file_path}`
            subject.quit
          end
        end
      end

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

        it "closes all files" do
          subject.subscribe(observer)
          expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
          expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
          lsof_after_quit = `lsof -p #{Process.pid} | grep #{file_path}`
          expect(lsof_after_quit).to be_empty
        end
      end

      context "when close_older is not set" do
        let(:quit_sleep) { 1.5 }

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

        it "the files are open before quitting" do
          subject.subscribe(observer)
          expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
          expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
          expect(lsof_before_quit.first).not_to be_empty
          lsof_after_quit = `lsof -p #{Process.pid} | grep #{file_path}`
          expect(lsof_after_quit).to be_empty
        end
      end

      context "when close_older is set" do
        let(:before_proc) { FileWatch::NullCallable }
        let(:quit_proc)   { FileWatch::NullCallable }

        subject do
          FileWatch::Tail.new_observing(
            :sincedb_path => sincedb_path,
            :start_new_files_at => :beginning,
            :stat_interval => 0.1,
            :close_older => 1)
        end

        before :each do
          subject.tail(file_path)
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end

        it "the files are closed before quitting" do
          RSpec::Sequencing
          .run("begin tailing") do
            subject.tail(File.join(directory, "*"))
          end
          .then("create file") do
            File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          end
          .then_after(2.55, "quit") do
            lsof_before_quit.push `lsof -p #{Process.pid} | grep #{file_path}`
            subject.quit
          end

          subject.subscribe(observer)
          expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
          expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof, :timed_out])
          expect(lsof_before_quit.first).to be_empty
        end
      end
    end
  end
end
