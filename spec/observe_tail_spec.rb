require 'filewatch/tail'
require 'stud/temporary'
require_relative 'helpers/spec_helper'

describe "FileWatch::Tail (observing)" do
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

  after :each do
    FileUtils.rm_rf(file_path)
    FileUtils.rm_rf(sincedb_path)
  end

  context "when watching before files exist (start at end)" do
    subject { FileWatch::Tail.new_observing(
      :sincedb_path => sincedb_path, :stat_interval => 0.05) }

    it "reads new lines off the file" do
      RSpec::Sequencing
        .run("tail then create file") do
          subject.tail(file_path)
          File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
        end
        .then_after(0.55, "quit") do
          subject.quit
        end
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
      # NOTE: if the stat_interval is too fast we can begin before ruby completes writing the file
      # So we get an eof (empty file) during the create read step.
      # in this case the calls are [:create, :eof, :accept, :accept, :eof]
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
    end
  end

  context "when watching after files exist" do
    subject { FileWatch::Tail.new_observing(
      :sincedb_path => sincedb_path, :start_new_files_at => :beginning,
      :stat_interval => 0.05) }

    it "reads new lines off the file" do
      RSpec::Sequencing
        .run("create file then tail") do
          File.open(file_path, "wb") { |file| file.write("lineA\nlineB\n") }
          subject.tail(file_path)
        end
        .then_after(0.55, "quit") do
          subject.quit
        end
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["lineA", "lineB"])
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
    end
  end

  context "when watching a CRLF file" do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path,
                                  :stat_interval => 0.05,
                                  :start_new_files_at => :end,
                                  :delimiter => "\r\n") }

    it "reads new lines off the file" do
      RSpec::Sequencing
        .run("create empty file then tail then append") do
          FileUtils.touch(file_path)
          subject.tail(file_path)
        end
        .then_after(0.1, "append data to file after allowing the empty file to be seen") do
          File.open(file_path, "ab") { |file| file.write("lineC\r\nlineD\r\n") }
        end
        .then_after(0.55, "quit") do
          subject.quit
        end
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["lineC", "lineD"])
      expect(observer.listeners[file_path].calls).to eq([:create, :eof, :accept, :accept, :eof])
    end
  end

  context "when a file is deleted" do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0.05) }

    it "should read the lines and call deleted on listener" do
      RSpec::Sequencing
        .run("create file then tail") do
          File.open(file_path, "w") { |file| file.write("line1\nline2\n") }
          subject.tail(file_path)
        end
        .then_after(0.55, "delete the file") do
          FileUtils.rm(file_path)
        end
        .then_after(0.55, "quit") do
          subject.quit
        end
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof, :eof, :delete])
    end
  end

  describe "sincedb" do
    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0.05) }

    context "when reading a new file" do
      it "updates sincedb after subscribe" do
        RSpec::Sequencing
          .run("create file then begin tailing") do
            File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
            subject.tail(file_path)
          end
          .then_after(0.55, "quit tailing") do
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
        .run("create file then begin tailing") do
          File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
          stats << File::Stat.new(file_path)
          subject.tail(file_path)
        end
        .then_after(0.55, "quit tailing") do
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
    subject { FileWatch::Tail.new_observing(
      :sincedb_path => sincedb_path, :start_new_files_at => :beginning,
      :stat_interval => 0.05) }

    it "should read all the lines entirely" do
      RSpec::Sequencing
        .run("write large amount of data to file") do
          IO.write(file_path, "#{lineA}\n#{lineB}\n#{lineC}\n")
        end
        .then_after(0.1, "begin tailing") do
          subject.tail(file_path)
        end
        .then_after(0.55, "quit") do
          subject.quit
        end
      subject.subscribe(observer)
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :accept, :eof])
      expect(observer.listeners[file_path].lines).to eq([lineA, lineB, lineC])
    end
  end

  context "when watching a directory" do
    let(:directory) { Stud::Temporary.directory }
    let(:file_path) { File.join(directory, "1.log") }
    let(:glob_path) { File.join(directory, "*.log") }
    let(:position)  { :beginning }
    let(:result_cache) { Hash.new }

    subject { FileWatch::Tail.new_observing(:sincedb_path => sincedb_path, :start_new_files_at => position, :stat_interval => 0) }

    after :each do
      FileUtils.rm_rf(directory)
    end

    it "reads new lines off the file" do
      RSpec::Sequencing
        .run("create file and tail") do
          File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
          subject.tail(glob_path)
        end
        .then_after(0.55, "quit") do
          subject.quit
        end
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
    end

    context "when a file is renamed outside the watch pattern" do
      let(:new_file_path) { file_path + ".bak" }

      it "'deletes' the old file and does not re-read the renamed file" do
        RSpec::Sequencing
          .run("create file and tail") do
            File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
            subject.tail(glob_path)
          end
          .then_after(1, "rename file") do
            result_cache[:before_lines] = observer.listeners[file_path].lines.dup
            result_cache[:before_calls] = observer.listeners[file_path].calls.dup
            FileUtils.mv(file_path, new_file_path)
          end
          .then_after(1, "quit") do
            subject.quit
          end
        subject.subscribe(observer)
        expect(observer.listeners[file_path].lines).to eq(result_cache[:before_lines])
        expect(result_cache[:before_calls]).to         eq([:create, :accept, :accept, :eof])
        expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof, :eof, :delete])
        expect(observer.listeners[new_file_path].calls).to eq([])
      end
    end

    context "when a file is renamed inside the watch pattern" do
      let(:new_file_path) { File.join(directory, "1renamed.log") }

      it "'deletes' the old file and does not re-read the renamed file" do
        RSpec::Sequencing
          .run("create file and tail") do
            File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
            subject.tail(glob_path)
          end
          .then_after(0.55, "rename file after allowing time to read the original") do
            result_cache[:before_lines] = observer.listeners[file_path].lines.dup
            result_cache[:before_calls] = observer.listeners[file_path].calls.dup
            FileUtils.mv(file_path, new_file_path)
          end
          .then_after(0.55, "quit") do
            subject.quit
          end
        subject.subscribe(observer)
        expect(observer.listeners[file_path].lines).to eq(result_cache[:before_lines])
        expect(result_cache[:before_calls]).to         eq([:create, :accept, :accept, :eof])
        expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof, :eof, :delete])
        expect(observer.listeners[new_file_path].lines).to eq([])
        expect(observer.listeners[new_file_path].calls).to eq([:create, :eof])
      end
    end

    context "when a file is copied outside the the watch pattern and the original truncated" do
      let(:new_file_path) { file_path + ".bak" }

      it "does not re-read the original file" do
        RSpec::Sequencing
          .run("create file and tail") do
            File.open(file_path, "wb") { |file| file.write("line1\nline2\nline3\nline4\n") }
            subject.tail(glob_path)
          end
          .then_after(0.55, "copy file then truncate and add content after allowing time to read the original") do
            FileUtils.cp(file_path, new_file_path)
            # open for "w" will truncate and add new lines
            File.open(file_path, "w") {|f| f.write("lineA\nlineB\n"); f.fsync}
          end
          .then_after(0.55, "quit") do
            subject.quit
          end
        subject.subscribe(observer)
        # sometimes the truncated file is read before the content is written we get an extra eof
        # this is normal and should not cause a test failure
        calls = observer.listeners[file_path].calls
        if calls.slice(8, 5) == [:create, :eof, :accept, :accept, :eof]
          expect(calls.delete_at(9)).to eq(:eof)
        end
        expect(calls).to eq(
          [:create, :accept, :accept, :accept, :accept, :eof, :eof, :delete, :create, :accept, :accept, :eof]
        )
        expect(observer.listeners[file_path].lines).to eq(["line1", "line2", "line3", "line4", "lineA", "lineB"])
      end
    end

    context "when a file that was modified more than 10 seconds ago is present" do
      subject { FileWatch::Tail.new_observing(
        :sincedb_path => sincedb_path, :start_new_files_at => position,
        :stat_interval => 0.1, :ignore_older => 10) }

      it "the file is ignored" do
        RSpec::Sequencing
          .run("create file older than ignore_older and tail") do
            File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
            FileWatch.make_file_older(file_path, 25)
            subject.tail(File.join(directory, "*"))
          end
          .then_after(0.55, "quit") do
            subject.quit
          end
        subject.subscribe(observer)
        expect(observer.listeners[file_path].lines).to eq([])
        expect(observer.listeners[file_path].calls).to eq([])
      end

      context "and then it is written to" do
        it "reads only the new lines off the file" do
          RSpec::Sequencing
          .run("create file older than ignore_older and tail") do
            File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
            FileWatch.make_file_older(file_path, 25)
            subject.tail(File.join(directory, "*"))
          end
          .then_after(0.55, "write more lines") do
            File.open(file_path, "ab") { |file| file.write("line3\nline4\n") }
          end
          .then_after(0.55, "quit") do
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

      context "when quiting and close_older is not set" do
        subject do
          FileWatch::Tail.new_observing(
            :sincedb_path => sincedb_path,
            :stat_interval => 0.1)
        end

        it "files are open before quit and closed after" do
          RSpec::Sequencing
            .run("tail then create file") do
              subject.tail(file_path)
              File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
            end
            .then_after(0.55, "quit") do
              lsof_before_quit.push `lsof -p #{Process.pid} | grep #{file_path}`
              subject.quit
            end
          subject.subscribe(observer)
          expect(observer.listeners[file_path].lines).to eq(["line1", "line2"])
          expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
          lsof_after_quit = `lsof -p #{Process.pid} | grep #{file_path}`
          expect(lsof_after_quit).to be_empty
        end
      end

      context "when close_older is set" do
        subject do
          FileWatch::Tail.new_observing(
            :sincedb_path => sincedb_path,
            :start_new_files_at => :beginning,
            :stat_interval => 0.1,
            :close_older => 1)
        end

        it "the files are closed before quitting" do
          RSpec::Sequencing
          .run("begin tailing then create file") do
            subject.tail(file_path)
            File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
          end
          .then_after(1.75, "allow time to have files closed then quit") do
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
