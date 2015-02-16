require 'filewatch/tail'
require 'stud/temporary'

describe FileWatch::Tail do

  let(:file_path) { Stud::Temporary.file.path }
  let(:sincedb_path) { Stud::Temporary.file.path }

  context "when watching a file" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning) }

    before :each do
      File.open(file_path, "w") { |file|  file.write("line1\nline2\n") }
      subject.tail(file_path)
    end

    it "reads new lines off the file" do
      Thread.new(subject) { sleep 0.1; subject.quit } # force the subscribe loop to exit
      expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"])
    end
  end

  context "when watching a CRLF file" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path,
                                  :start_new_files_at => :beginning,
                                  :delimiter => "\r\n") }

    before :each do
      File.open(file_path, "w") { |file|  file.write("line1\r\nline2\r\n") }
      subject.tail(file_path)
    end

    it "reads new lines off the file" do
      Thread.new(subject) { sleep 0.1; subject.quit } # force the subscribe loop to exit
      expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"])
    end
  end
end

