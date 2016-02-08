require 'filewatch/watch'
require 'filewatch/watched_file'
# require 'stud/temporary'
require_relative 'helpers/spec_helper'

describe FileWatch::WatchedFile do
  let(:path)  { FileWatch.path_to_fixture("ten_alpha_lines.txt") }
  let(:stat)  { File.stat(path) }
  let(:inode) { FileWatch::Watch.inode(path, stat) }
  let(:raw_inode) { inode.first }
  let(:position)  { 12 }

  subject { described_class.new_ongoing(path, inode, stat) }

  context "when serializing" do
    it "builds a string" do
      regex = %r~\d{3,9} 0 0 0 W \d{9,13}\.0 \d{9,13}\.0 \d{1,13} #{path} watched\s~
      expect(subject.serialize).to match(regex)
    end
  end
  context "when deserializing from a string" do
    it "builds a new instance" do
      str = subject.serialize
      obj = described_class.deserialize(str)
      expect(obj.path).to eq(path)
      expect(obj.inode).to eq([inode.first, 0, 0])
      expect(obj.bytes_read).to eq(0)
      expect(obj.state).to eq(:watched)
      expect(obj.state_history).to eq([])
      expect(obj.created_at).to be_a(Float)
    end
  end

  context "when deserializing from a sincedb string" do
    it "builds an incomplete object" do
      obj = described_class.deserialize("#{raw_inode} 1 4 #{position}")
      expect(obj.path).to eq("unknown")
      expect(obj.inode).to eq([raw_inode, 0, 0])
      expect(obj.bytes_read).to eq(position)
      expect(obj.state).to eq(:watched)
      expect(obj.state_history).to eq([])
      expect(obj.created_at).to eq(0.0)
    end
  end

  describe "comparing two watched_files" do
    context "when using an entry read from the old sincedb for the same inode" do
      it "is not equivalent to one discovered" do
        since_obj = described_class.deserialize("#{raw_inode} 1 4 #{position}")
        expect(since_obj.storage_key).not_to eq(subject.storage_key)
        expect(since_obj.equivalent?(subject)).to be_falsey
      end
    end

    context "when using an entry read from the new sincedb for the same file that was not read at all" do
      it "is equivalent to one discovered" do
        since_obj = described_class.deserialize(subject.serialize)
        expect(since_obj.storage_key).to eq(subject.storage_key)
        expect(since_obj.equivalent?(subject)).to be_truthy
        expect(since_obj.bytes_read).to eq(subject.bytes_read)
        expect(since_obj.content_read_equal?(subject)).to be_falsey
      end
    end

    context "when using an entry read from the new sincedb for the same file that was read fully" do
      it "is equal to one discovered" do
        subject.update_bytes_read(subject.last_stat_size) # simulate reading the file before serialization
        since_obj = described_class.deserialize(subject.serialize)
        subject.update_bytes_read(0) # discovered files default to zero bytes read
        expect(since_obj.storage_key).to eq(subject.storage_key)
        expect(since_obj.equivalent?(subject)).to be_truthy
        expect(since_obj.content_read_equal?(subject)).to be_truthy
      end
    end
  end
end
