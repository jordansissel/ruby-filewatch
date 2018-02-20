require_relative 'helpers/spec_helper'

describe FileWatch::Watch4Test do
  before(:all) do
    @thread_abort = Thread.abort_on_exception
    Thread.abort_on_exception = true
  end

  after(:all) do
    Thread.abort_on_exception = @thread_abort
  end

  let(:directory) { Stud::Temporary.directory }
  let(:watch_dir) { File.join(directory, "*.log") }
  let(:file_path) { File.join(directory, "1.log") }
  let(:loggr)     { FileWatch::FileLogTracer.new }
  let(:results)   { [] }
  let(:stat_interval) { 0.1 }
  let(:discover_interval) { 4 }
  let(:opts) { {} }
  let(:discoverer) { FileWatch::Discover.new(opts, loggr) }
  let(:sincedb) { FileWatch::SinceDb.new(opts, loggr) }

  let(:subscribe_proc) do
    lambda do
      formatted_puts("subscribing")
      subject.subscribe(stat_interval, discover_interval) do |event, wf|
        results.push([event, wf.path])
        # fake that we actually opened and read the file
        wf.update_bytes_read(wf.filestat.size) if event == :grow
      end
    end
  end

  subject do
    watch = FileWatch::Watch4Test.new(opts)
    watch.logger = loggr
    discoverer.add_converter(FileWatch::SinceDbConverter.new(sincedb, loggr))
    watch.add_discoverer(discoverer)
  end

  after do
    FileUtils.rm_rf(directory)
  end

  describe "max open files" do
    let(:max) { 1 }
    let(:file_path2) { File.join(directory, "2.log") }
    let(:wait_before_quit) { 0.25 }
    let(:actions) do
      RSpec::Sequencing
        .run("create file and watch directory") do
          File.open(file_path2, "wb") { |file| file.write("lineA\nlineB\n") }
          File.open(file_path, "wb")  { |file| file.write("line1\nline2\n") }
          subject.watch(watch_dir)
        end
        .then_after(wait_before_quit, "quit after a short time") do
          subject.quit
        end
    end

    before { actions.activate }
    after do
      ENV.delete("FILEWATCH_MAX_OPEN_FILES")
      ENV.delete("FILEWATCH_MAX_FILES_WARN_INTERVAL")
    end

    context "when using ENV" do
      it "opens only 1 file" do
        ENV["FILEWATCH_MAX_OPEN_FILES"] = max.to_s
        ENV["FILEWATCH_MAX_FILES_WARN_INTERVAL"] = "0"
        expect(subject.max_active).to eq(max)
        subscribe_proc.call
        expect(results).to eq([[:create_initial, file_path], [:grow, file_path]])
        expect(loggr.trace_for(:warn).flatten.last).to match(
          %r{Reached open files limit: 1, set by the 'max_open_files' option or default, try setting close_older})
      end
    end

    context "when using #max_open_files=" do
      it "opens only 1 file" do
        expect(subject.max_active).to eq(4095)
        subject.max_open_files = max
        expect(subject.max_active).to eq(max)
        subscribe_proc.call
        expect(results).to eq([[:create_initial, file_path], [:grow, file_path]])
      end
    end

    context "when close_older is set" do
      let(:wait_before_quit) { 1.25 }

      it "opens both files" do
        opts.update(:close_older => 0.75) #seconds
        ENV["FILEWATCH_MAX_FILES_WARN_INTERVAL"] = "0.8"
        subject.max_open_files = max
        subscribe_proc.call
        expect(results).to eq([
            [:create_initial, file_path], [:grow, file_path], [:timeout, file_path],
            [:create_initial, file_path2], [:grow, file_path2], [:timeout, file_path2]
          ])
        expect(loggr.trace_for(:warn).flatten.last).to match(
          %r{Reached open files limit: 1, set by the 'max_open_files' option or default, try setting close_older. There are})
      end
    end
  end

  context "when watching a directory with files" do
    let(:actions) do
      RSpec::Sequencing
        .run("create file then start watching when directory has files") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          subject.watch(watch_dir)
        end
        .then_after(0.55, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial and one grow file events" do
      actions.activate
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:grow, file_path]])
    end
  end

  context "when watching a directory without files and one is added" do
    before do
      RSpec::Sequencing
        .run("start watching before any files are written") do
          subject.watch(watch_dir)
        end
        .then_after(0.25, "create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.45, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create and one grow file events" do
      subscribe_proc.call
      expect(results).to eq([[:create, file_path], [:grow, file_path]])
    end
  end

  describe "file is not longer readable" do
    let(:quit_after) { 0.1 }
    let(:stat)  { double("stat", :size => 100, :ctime => Time.now, :mtime => Time.now, :ino => 234567, :dev_major => 3, :dev_minor => 2) }
    let(:watched_file) { FileWatch::WatchedFile.new_ongoing(file_path, stat) }

    before do
      discoverer.files.store(file_path, watched_file)
    end

    context "when subscribed and a closed file is no longer readable" do
      before { watched_file.close }
      it "it is deleted from the @files hash" do
        RSpec::Sequencing.run_after(quit_after, "quit") { subject.quit }
        subscribe_proc.call
        expect(discoverer.files.size).to eq(0)
        expect(results).to eq([])
      end
    end

    context "when subscribed and an ignored file is no longer readable" do
      before { watched_file.ignore }
      it "it is deleted from the @files hash" do
        RSpec::Sequencing.run_after(quit_after, "quit") { subject.quit }
        subscribe_proc.call
        expect(discoverer.files.size).to eq(0)
        expect(results).to eq([])
      end
    end

    context "when subscribed and a watched file is no longer readable" do
      before { watched_file.watch }
      it "it is deleted from the @files hash" do
        RSpec::Sequencing.run_after(quit_after, "quit") { subject.quit }
        subscribe_proc.call
        expect(discoverer.files.size).to eq(0)
        expect(results).to eq([[:delete, file_path]])
      end
    end

    context "when subscribed and an active file is no longer readable" do
      before { watched_file.activate }
      it "yields a delete event and it is deleted from the @files hash" do
        RSpec::Sequencing.run_after(quit_after, "quit") { subject.quit }
        subscribe_proc.call
        expect(discoverer.files.size).to eq(0)
        expect(results).to eq([[:delete, file_path]])
      end
    end
  end

  context "when watching a directory with files and a file is renamed to not match glob" do
    let(:new_file_path) { file_path + ".old" }
    before do
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.25, "start watching after files are written") do
          subject.watch(watch_dir)
        end
        .then_after(0.55, "rename file") do
          FileUtils.mv(file_path, new_file_path)
        end
        .then_after(0.55, "then write to renamed file") do
          File.open(new_file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(0.45, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial, one grow and a delete file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:grow, file_path], [:delete, file_path]])
    end
  end

  context "when watching a directory with files and a file is renamed to match glob" do
    let(:new_file_path) { file_path + "2.log" }
    before do
      opts.update(:close_older => 0)
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.15, "start watching after files are written") do
          subject.watch(watch_dir)
        end
        .then_after(0.55, "rename file") do
          FileUtils.mv(file_path, new_file_path)
        end
        .then("then write to renamed file") do
          File.open(new_file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(0.55, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial, a grow, a delete, a create and a grow file events" do
      subscribe_proc.call
      expect(results).to eq([
          [:create_initial, file_path], [:grow, file_path], [:delete, file_path],
          [:create, new_file_path], [:grow, new_file_path]
        ])
    end
  end

  context "when watching a directory with files and data is appended" do
    before do
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.25, "start watching after file is written") do
          subject.watch(watch_dir)
        end
        .then_after(0.45, "append more lines to the file") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(0.45, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial, a grow, a create (after the fingerprint changed) and a grow file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:grow, file_path], [:create, file_path], [:grow, file_path]])
    end
  end

  context "when close older expiry is enabled" do
    before do
      opts.update(:close_older => 2)
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then("start watching before file ages more than close_older") do
          subject.watch(watch_dir)
        end
        .then_after(2.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, grow and timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:grow, file_path], [:timeout, file_path]])
    end
  end

  context "when close older expiry is enabled and after timeout the file is appended-to" do
    before do
      opts.update(:close_older => 2)

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then("start watching before file ages more than close_older") do
          subject.watch(watch_dir)
        end
        .then_after(2.1, "append more lines to file after file ages more than close_older") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(2.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, grow, timeout then grow, timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:grow, file_path], [:timeout, file_path], [:grow, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore older expiry is enabled and all files are already expired" do
    before do
      opts.update(:ignore_older => 1)

      RSpec::Sequencing
        .run("create file older than ignore_older and watch") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          FileWatch.make_file_older(file_path, 15)
          subject.watch(watch_dir)
        end
        .then_after(1.1, "quit") do
          subject.quit
        end
    end

    it "yields no file events" do
      subscribe_proc.call
      expect(results).to eq([])
    end
  end

  context "when ignore_older is less than close_older and all files are not expired" do
    before do
      opts.update(:close_older => 2, :ignore_older => 1)

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then("start watching before file age reaches ignore_older") do
          subject.watch(watch_dir)
        end
        .then_after(2.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, grow, timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:grow, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore_older is less than close_older and all files are expired" do
    before do
      opts.update(:close_older => 2, :ignore_older => 10)

      RSpec::Sequencing
        .run("create file older than ignore_older and watch") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          FileWatch.make_file_older(file_path, 15)
          subject.watch(watch_dir)
        end
        .then_after(1.55, "quit after allowing time to check the files") do
          subject.quit
        end
    end

    it "yields no file events" do
      subscribe_proc.call
      expect(results).to eq([])
    end
  end

  context "when ignore older and close older expiry is enabled and after timeout the file is appended-to" do
    before do
      opts.update(:close_older => 2, :ignore_older => 20)

      RSpec::Sequencing
        .run("create file older than ignore_older and watch") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          FileWatch.make_file_older(file_path, 25)
          subject.watch(watch_dir)
        end
        .then_after(0.15, "append more lines to file after file ages more than ignore_older") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(2.0, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields unignore, grow then timeout file events" do
      subscribe_proc.call
      expect(results).to eq([
          [:unignore, file_path], [:grow, file_path], [:timeout, file_path]
        ])
    end
  end
end
