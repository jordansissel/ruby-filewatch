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
  let(:quit_proc) do
    lambda do
      Thread.new do
        sleep 1
        subject.quit
      end
    end
  end
  let(:subscribe_proc) do
    lambda do
      subject.subscribe(0.1, 4) do |event, path|
        results.push([event, path])
      end
    end
  end
  let(:write_lines_1_and_2_proc) do
    lambda do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
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
    let(:write_lines_3_and_4_proc) do
      lambda do
        Thread.new do
          sleep 0.5
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
      end
    end

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

end
