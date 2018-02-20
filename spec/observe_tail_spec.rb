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
  let(:directory) { Stud::Temporary.directory }
  let(:dir_sdb) { Stud::Temporary.directory }
  let(:file_path) { File.join(directory, "1.log") }
  let(:sincedb_path) { File.join(dir_sdb, "sincedb.log") }
  let(:sincedb_v1_regex) { %r|\d{6,10} \d{1,2} \d{1,2} \d{1,10} \d+\.\d+\s?| }
  let(:opts) { {:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0.05} }

  after :each do
    FileUtils.rm_rf(dir_sdb)
    FileUtils.rm_rf(directory)
  end

  let(:_cache) { [] }

  context "when sincedb path is given but ENV[\"HOME\"] is not given" do
    before { _cache << ENV.delete("HOME") }
    after  { _cache.first.tap{|s| ENV["HOME"] = s unless s.nil?} }

    it "should not raise an exception" do
      expect do
        FileWatch::Tail.new_observing(opts)
      end.not_to raise_error
    end
  end

  context "when sincedb path is given but ENV[\"SINCEDB_PATH\"] is not given" do
    before { _cache << ENV.delete("SINCEDB_PATH") }
    after  { _cache.first.tap{|s| ENV["SINCEDB_PATH"] = s unless s.nil?} }

    it "should not raise an exception" do
      expect do
        FileWatch::Tail.new_observing(opts)
      end.not_to raise_error
    end
  end

  context "when watching before files exist (start at end)" do
    subject { FileWatch::Tail.new_observing(opts) }

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
    subject { FileWatch::Tail.new_observing(opts) }

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
    subject { FileWatch::Tail.new_observing(opts.update(:start_new_files_at => :end,
                                  :delimiter => "\r\n")) }

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
      expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
    end
  end

  context "when a file is deleted" do
    subject { FileWatch::Tail.new_observing(opts) }

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

  describe "sincedb operations" do
    subject { FileWatch::Tail.new_observing(opts) }

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
        expect(File.read(sincedb_path)).to match(FileWatch.sincedb_v2_regex)
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
        expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :eof])
      end

      it "updates on tail.quit" do
        restart_actions.activate
        subject.subscribe(observer)
        subject.subscribe(observer)
        restart_actions.value
        expect(results.first).to match(FileWatch.sincedb_v2_regex(stats.first.size))
        expect(results.last).to match(FileWatch.sincedb_v2_regex(stats.last.size))
      end
    end

    context "when a v1 record exists it is converted to a v2 record" do
      let(:file_path) { FileWatch.path_to_fixture("big1.txt") }
      before { IO.write(sincedb_path, FileWatch.v1_sdb_rec_for_big1_file) }
      it "converts the v1 sincedb record but does not read the file as it was read before" do
        RSpec::Sequencing
          .run("begin tailing") do
            subject.tail(file_path)
          end
          .then_after(0.25, "quit") do
            subject.quit
          end
        subject.subscribe(observer)
        expect(observer.listeners[file_path].lines.count).to eq(0)
        expect(File.read(sincedb_path)).to match(FileWatch.sincedb_v2_regex)
      end
    end
  end

  context "ingesting files bigger than 32k" do
    let(:tailer) { FileWatch::Tail.new_observing(opts) }
    let(:lines) { FileWatch.lines_for_45K_file }
    let(:actions) do
      RSpec::Sequencing
        .run_after(0.55, "quit") do
          tailer.quit
        end
    end
    context "with an empty sincedb file" do
      before do
        File.open(file_path, "wb") { |file| file.write("#{lines[0]}\n#{lines[1]}\n#{lines[2]}\n") }
        tailer.tail(file_path)
      end
      it "reads all the lines entirely" do
        actions.activate
        tailer.subscribe(observer)
        expect(observer.listeners[file_path].calls).to eq([:create, :accept, :accept, :accept, :eof])
        expect(observer.listeners[file_path].lines).to eq(FileWatch.lines_for_45K_file)
      end
    end
    context "with a sincedb record" do
      before do
        File.open(sincedb_path, "wb") { |file| file.write(FileWatch.sdb_rec_for_45k_file) }
        File.open(file_path, "wb") { |file| file.write("#{lines[0]}\n#{lines[1]}\n#{lines[2]}\n") }
        tailer.tail(file_path)
      end
      it "does not read any lines" do
        actions.activate
        tailer.subscribe(observer)
        expect(observer.listeners[file_path].calls).to eq([])
        expect(observer.listeners[file_path].lines).to eq([])
      end
    end
  end

  context "when using the json serializer" do
    let(:file_path) { FileWatch.path_to_fixture("twenty_six_lines.txt") }
    let(:results) { [] }

    subject { FileWatch::Tail.new_observing(opts) }

    after :each do
      FileUtils.rm_rf(directory)
    end

    it "writes the sincedb as json" do
      subject.serializer = FileWatch::JsonSerializer
      RSpec::Sequencing
        .run("begin tailing") do
          subject.tail(file_path)
        end
        .then_after(0.25, "quit") do
          subject.quit
        end
      subject.subscribe(observer)
      expect(observer.listeners[file_path].lines.count).to eq(26)
      File.open(sincedb_path) {|file| results.concat(FileWatch::Json.load(file))}
      expect(results.first).to match({"version"=>"1.0"})
      record = results.last
      expect(record["position"]).to eq(494)
      expect(record["last_seen"]).to be_within(1.0).of(Time.now.to_f)
      expect(record["path"]).to eq(file_path)
      if FileWatch.on_windows?
        expect(record["state"].keys).to eq(["vol", "idxlo", "idxhi"])
      else
        expect(record["state"].keys).to eq(["inode", "device_minor", "device_major"])
      end
      expect(record["fingerprints"].first).to eq({"hash"=>1180824822273425351, "offset"=>0, "size"=>255, "algo"=>"fnv"})
    end
  end

  context "when watching a directory" do
    let(:glob_path) { File.join(directory, "*.log") }
    let(:result_cache) { Hash.new }

    subject { FileWatch::Tail.new_observing(opts) }

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
        expect(observer.listeners[new_file_path].calls).to eq([])
      end
    end

    context "when a file is copied outside the the watch pattern and the original truncated" do
      let(:new_file_path) { file_path + ".bak" }
      let(:lines) { ["line1\nline2\nline3\nline4\n", "lineA\nlineB\n"] }
      let(:actions) do
        RSpec::Sequencing
          .run("create file and tail") do
            File.open(file_path, "wb") { |file| file.write(lines[0]) }
            subject.tail(glob_path)
          end
          .then_after(0.55, "copy file then truncate and add content after allowing time to read the original") do
            FileUtils.cp(file_path, new_file_path)
            # open for "w" will truncate and add new lines
            File.open(file_path, "w") {|f| f.write(lines[1]); f.fsync}
          end
          .then_after(0.55, "quit") do
            subject.quit
          end
      end

      context "when the additional data is less than before" do
        before do
          actions.activate
        end
        it "resets the read point and reads appended data" do
          subject.subscribe(observer)
          calls = observer.listeners[file_path].calls
          expect(calls).to eq(
            [:create, :accept, :accept, :accept, :accept, :eof, :accept, :accept, :eof]
          )
          expect(observer.listeners[file_path].lines).to eq(["line1", "line2", "line3", "line4", "lineA", "lineB"])
        end
      end

      context "when the additional data is more than before" do
        before do
          lines.rotate!
          actions.activate
        end
        it "resets the read point and reads appended data" do
          subject.subscribe(observer)
          calls = observer.listeners[file_path].calls
          expect(calls).to eq(
            [:create, :accept, :accept, :eof, :accept, :accept, :accept, :accept, :eof]
          )
          expect(observer.listeners[file_path].lines).to eq(["lineA", "lineB", "line1", "line2", "line3", "line4" ])
        end
      end
    end

    context "when reading big files in alternation" do
      subject { FileWatch::Tail.new_observing(opts.update(:read_iterations => 1)) }
      let(:glob) { FileWatch.path_to_fixture("big*.txt") }
      let(:big1) { FileWatch.path_to_fixture("big1.txt") }
      let(:big2) { FileWatch.path_to_fixture("big2.txt") }

      it "both files are read showing alternation" do
        subject.tail(glob)
        RSpec::Sequencing
          .run_after(1.5, "quit") { subject.quit }
        subject.subscribe(observer)
        expect(observer.listeners[big1].accepts.slice(420, 10)).to eq([421, 422, 423, 424, 849, 850, 851, 852, 853, 854])
        expect(observer.listeners[big2].accepts.take(10)).to eq([425, 426, 427, 428, 429, 430, 431, 432, 433, 434])
        expect(observer.listeners[big1].lines.last).to match(/process PID changed from 39998 to 39999/)
        expect(observer.listeners[big2].lines.last).to match(/process PID changed from 59998 to 59999/)
      end
    end

    context "for spec_helper 'songs1_short', when track1 was read and is in the sincedb" do
      # designed to test find using short keys when a value is found (from disk) and
      # the wf is not allocated - it begins from the read bytes offset
      let(:songs) { File.join(directory, "pl1.log") }
      before do
        File.open(sincedb_path, "wb") { |file| file.write(FileWatch.short_sdb_rec_for_songs1) }
      end

      it "reads track 2 only" do
        RSpec::Sequencing
          .run("create the song file") do
            File.open(songs, "wb") { |file| file.write(FileWatch.songs1_short) }
            subject.tail(glob_path)
          end
          .then_after(0.55, "quit") do
            subject.quit
          end
        subject.subscribe(observer)
        expect(observer.listeners[songs].lines).to eq([FileWatch.songs1_short.split("\n")[1]])
      end
    end

    context "when two files start with the same content and then diverge" do
      let(:header) { "title, artist, album, date, genre, track_no"}

      let(:playlist1) { File.join(directory, "pl1.log") }
      let(:playlist2) { File.join(directory, "pl2.log") }
      let(:actions_pre) do
        RSpec::Sequencing
          .run("create both files with the same header then tail") do
            File.open(playlist1, "wb") { |file| file.puts(header) }
            File.open(playlist2, "wb") { |file| file.puts(header) }
            subject.tail(File.join(directory, "*"))
          end
      end
      let(:actions_post) do
        RSpec::Sequencing
          .run_after(0.25, "add the songs") do
            File.open(playlist1, "ab") { |file| file.write(songs1) }
            File.open(playlist2, "ab") { |file| file.write(songs2) }
          end
          .then_after(0.55, "quit") do
            subject.quit
          end
      end
      before do
        actions_pre.activate
        actions_pre.value
        actions_post.activate
      end

      context "using short fingerprints" do
        let(:songs1) { FileWatch.songs1_short }
        let(:songs2) { FileWatch.songs2_short }

        it "both files are read" do
          subject.subscribe(observer)
          expect(observer.listeners[playlist1].lines).to eq(songs1.split("\n").unshift(header))
          expect(observer.listeners[playlist2].lines).to eq(songs2.split("\n").unshift(header))
        end
      end

      context "using long fingerprints" do
        let(:songs1) { FileWatch.songs1 }
        let(:songs2) { FileWatch.songs2 }
        it "both files are read" do
          subject.subscribe(observer)
          expect(observer.listeners[playlist1].lines).to eq(songs1.split("\n").unshift(header))
          expect(observer.listeners[playlist2].lines).to eq(songs2.split("\n").unshift(header))
        end
      end
    end

    context "when a file that was modified more than 10 seconds ago is present" do
      subject { FileWatch::Tail.new_observing(opts.update(:ignore_older => 10)) }

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

  if !FileWatch.on_windows?
    describe "open or closed file handling" do
      let(:lsof_before_quit) { [] }

      context "when quiting and close_older is not set" do
        subject do
          FileWatch::Tail.new_observing(opts)
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
        subject { FileWatch::Tail.new_observing(opts.update(:close_older => 1)) }

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
