require 'filewatch/watch'
require 'stud/temporary'

describe FileWatch::Watch do
  before(:all) do
    @thread_abort = Thread.abort_on_exception
    Thread.abort_on_exception = true
  end

  after(:all) do
    Thread.abort_on_exception = @thread_abort
  end

  let(:directory) { Stud::Temporary.directory }
  let(:file_path) { File.join(directory, "1.log") }
  let(:loggr)     { double("loggr", :debug? => true) }
  let(:results)   { [] }
  let(:quit_sleep) { 1 }
  let(:stat_interval) { 0.1 }
  let(:discover_interval) { 4 }
  let(:write_3_and_4_sleep) { 0.5 }

  let(:quit_proc) do
    lambda do
      Thread.new do
        sleep quit_sleep
        subject.quit
      end
    end
  end

  let(:subscribe_proc) do
    lambda do
      subject.subscribe(stat_interval, discover_interval) do |event, path|
        results.push([event, path])
      end
    end
  end

  let(:write_lines_1_and_2_proc) do
    lambda do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
    end
  end

  let(:write_lines_3_and_4_proc) do
    lambda do
      Thread.new do
        sleep write_3_and_4_sleep
        File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
      end
    end
  end

  subject { FileWatch::Watch.new(:logger => loggr) }

  before do
    allow(loggr).to receive(:debug)
  end
  after do
    FileUtils.rm_rf(directory)
  end

  context "when watching a directory with files" do
    it "yields create_initial and one modify file events" do
      write_lines_1_and_2_proc.call
      subject.watch(File.join(directory, "*"))
      quit_proc.call
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path]])
    end
  end

  context "when watching a directory without files and one is added" do
    it "yields create and one modify file events" do
      subject.watch(File.join(directory, "*"))
      write_lines_1_and_2_proc.call

      quit_proc.call
      subscribe_proc.call

      expect(results).to eq([[:create, file_path], [:modify, file_path]])
    end
  end

  context "when watching a directory with files and data is appended" do


    it "yields create_initial and two modified file events" do
      write_lines_1_and_2_proc.call
      subject.watch(File.join(directory, "*"))

      write_lines_3_and_4_proc.call # asynchronous

      quit_proc.call
      subscribe_proc.call

      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:modify, file_path]])
    end
  end

  context "when unwatching a file and data is appended" do
    let(:write_lines_3_and_4_proc) do
      lambda do
        Thread.new do
          sleep 0.2
          results.clear
          subject.unwatch(file_path)
          sleep 0.2
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
      end
    end

    it "does not yield events after unwatching" do
      write_lines_1_and_2_proc.call
      subject.watch(File.join(directory, "*"))

      write_lines_3_and_4_proc.call # asynchronous

      quit_proc.call
      subscribe_proc.call

      expect(results).to eq([])
    end
  end

  context "when close older expiry is enabled" do
    let(:quit_sleep) { 3.5 }
    let(:stat_interval) { 0.2 }

    before do
      subject.close_older = 2
    end

    it "yields create_initial, modify and timeout file events" do
      write_lines_1_and_2_proc.call
      subject.watch(File.join(directory, "*"))
      quit_proc.call
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when close older expiry is enabled and after timeout the file is appended-to" do
    let(:quit_sleep) { 6.5 }
    let(:stat_interval) { 0.2 }
    let(:write_3_and_4_sleep) { 3.5 }

    before do
      subject.close_older = 2
    end

    it "yields create_initial, modify, timeout then modify, timeout file events" do
      write_lines_1_and_2_proc.call
      write_lines_3_and_4_proc.call # delayed async call
      subject.watch(File.join(directory, "*"))
      quit_proc.call
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore older expiry is enabled and all files are already expired" do
    let(:quit_sleep) { 3 }
    let(:stat_interval) { 0.2 }

    before do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.ignore_older = 1
    end

    it "yields only create_initial file event" do
      sleep 2
      subject.watch(File.join(directory, "*"))
      quit_proc.call
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path]])
    end
  end

  context "when ignore_older is less than close_older and all files are not expired" do
    let(:quit_sleep) { 3 }
    let(:stat_interval) { 0.2 }

    before do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.ignore_older = 1
      subject.close_older = 2
    end

    it "yields create_initial, modify, timeout file events" do
      subject.watch(File.join(directory, "*"))
      quit_proc.call
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore_older is less than close_older and all files are expired" do
    let(:quit_sleep) { 3 }
    let(:stat_interval) { 0.2 }

    before do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.ignore_older = 1
      subject.close_older = 2
    end

    it "yields create_initial, modify, timeout file events" do
      sleep 1.9
      subject.watch(File.join(directory, "*"))
      quit_proc.call
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:timeout, file_path]])
    end
  end
end
