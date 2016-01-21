require 'filewatch/watch'
require 'stud/temporary'
require_relative 'helpers/spec_helper'
## A note about the sequence delay times.
#  because the file mtimes and close_older etc.
#  are never more granular than 1 second,
#  when delay times are floats the measured time
#  can be rounded up or down.
#  so try to use float delays closer to the best integer
#  where it matters

describe FileWatch::Watch do
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

  let(:subscribe_proc) do
    lambda do
      formatted_puts("subscribing")
      subject.subscribe(stat_interval, discover_interval) do |event, watched_file|
        results.push([event, watched_file.path])
      end
    end
  end

  subject { FileWatch::Watch.new(:logger => loggr) }

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
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          File.open(file_path2, "wb") { |file|  file.write("lineA\nlineB\n") }
          subject.watch(watch_dir)
        end
        .then_after(wait_before_quit, "quit after a short time") do
          subject.quit
        end
    end

    before { actions.activate }
    after  { ENV.delete("FILEWATCH_MAX_OPEN_FILES") }

    context "when using ENV" do
      it "opens only 1 file" do
        ENV["FILEWATCH_MAX_OPEN_FILES"] = max.to_s
        expect(subject.max_active).to eq(max)
        subscribe_proc.call
        expect(results).to eq([[:create_initial, file_path], [:modify, file_path]])
      end
    end

    context "when using #max_open_files=" do
      it "opens only 1 file" do
        expect(subject.max_active).to eq(4095)
        subject.max_open_files = max
        expect(subject.max_active).to eq(max)
        subscribe_proc.call
        expect(results).to eq([[:create_initial, file_path], [:modify, file_path]])
      end
    end

    context "when close_older is set" do
      let(:wait_before_quit) { 2.25 }
      it "opens both files" do
        subject.max_open_files = max
        subject.close_older = 1 #seconds
        subscribe_proc.call
        expect(results).to eq([
            [:create_initial, file_path], [:modify, file_path], [:timeout, file_path],
            [:create_initial, file_path2], [:modify, file_path2], [:timeout, file_path2]
          ])
      end
    end
  end

  context "when watching a directory with files" do
    let(:actions) do
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.25, "start watching when directory has files") do
          subject.watch(watch_dir)
        end
        .then_after(0.55, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial and one modify file events" do
      actions.activate
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path]])
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

    it "yields create and one modify file events" do
      subscribe_proc.call
      expect(results).to eq([[:create, file_path], [:modify, file_path]])
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

    it "yields create_initial,one modify and a delete file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:delete, file_path]])
    end
  end

  context "when watching a directory with files and a file is renamed to match glob" do
    let(:new_file_path) { file_path + "2.log" }
    before do
      subject.close_older = 0
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
        .then("then write to renamed file") do
          File.open(new_file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(2.75, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial, a modify, a delete, a create and a modify file events" do
      subscribe_proc.call
      expect(results).to eq([
          [:create_initial, file_path], [:modify, file_path], [:delete, file_path],
          [:create, new_file_path], [:modify, new_file_path]
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

    it "yields create_initial and two modified file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:modify, file_path]])
    end
  end

  context "when unwatching a file and data is appended" do
    before do
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.25, "start watching after file is written") do
          subject.watch(watch_dir)
        end
        .then_after(0.25, "unwatch the file") do
          results.clear
          subject.unwatch(file_path)
        end
        .then_after(0.25, "append more lines to the file") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(0.45, "quit after a short time") do
          subject.quit
        end
    end

    it "does not yield events after unwatching" do
      subscribe_proc.call
      expect(results).to eq([])
    end
  end

  context "when close older expiry is enabled" do
    before do
      subject.close_older = 2
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then("start watching before file ages more than close_older") do
          subject.watch(watch_dir)
        end
        .then_after(3.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, modify and timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when close older expiry is enabled and after timeout the file is appended-to" do
    before do
      subject.close_older = 2

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then("start watching before file ages more than close_older") do
          subject.watch(watch_dir)
        end
        .then_after(3.1, "append more lines to file after file ages more than close_older") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(3.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, modify, timeout then modify, timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore older expiry is enabled and all files are already expired" do
    before do
      subject.ignore_older = 1

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(2, "start watching after file ages more than ignore_older") do
          subject.watch(watch_dir)
        end
        .then_after(1, "quit after allowing time to close the file") do
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
      subject.ignore_older = 1
      subject.close_older = 2

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then("start watching before file age reaches ignore_older") do
          subject.watch(watch_dir)
        end
        .then_after(3.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, modify, timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore_older is less than close_older and all files are expired" do
    before do
      subject.ignore_older = 1
      subject.close_older = 2

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(1.95, "start watching after file ages more than ignore_older") do
          subject.watch(watch_dir)
        end
        .then_after(1.25, "quit after allowing time to close the file") do
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
      subject.ignore_older = 2
      subject.close_older = 1

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(3.1, "start watching after file ages more than ignore_older") do
          subject.watch(watch_dir)
        end
        .then("append more lines to file after file ages more than ignore_older") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(2.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields unignore, modify then timeout file events" do
      subscribe_proc.call
      expect(results).to eq([
          [:unignore, file_path], [:modify, file_path], [:timeout, file_path]
        ])
    end
  end
end
