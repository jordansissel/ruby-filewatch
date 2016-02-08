require 'filewatch/watch'
require 'filewatch/watched_file'
require 'filewatch/watched_file_comparator'
require 'stud/temporary'
require_relative 'helpers/spec_helper'

describe FileWatch::WatchedFileComparator do
  let(:path)  { FileWatch.path_to_fixture("ten_alpha_lines.txt") }
  let(:stat)  { File.stat(path) }
  let(:inode) { FileWatch::Watch.inode(path, stat) }
  let(:raw_inode) { inode.first }
  let(:position) { stat.size } # we read it all
  let(:directory) { Stud::Temporary.directory }
  let(:serial_obj) do
    FileWatch::WatchedFile.new_ongoing(path, inode, stat).tap do |o|
      o.update_bytes_read(position)
      # give it some state history
      o.activate
      o.close
    end
  end
  let(:watched_obj) { FileWatch::WatchedFile.new_ongoing(path, inode, stat) }
  let(:serialize_str) { serial_obj.serialize }
  let(:sincedb_obj) { FileWatch::WatchedFile.deserialize(serialize_str) }

  context "when comparing watched_files from the same file read from disk and discovered" do
    it "is the same" do
      expect(sincedb_obj.storage_key).to eq(watched_obj.storage_key)
      expect(subject.compare_path_inode_same(watched_obj, sincedb_obj)).to eq(:same)
    end

    context "when the file has more content than was last saved" do
      let(:path)  { directory + "/afile.log" }
      let(:position) { 6 } # we read 6 bytes
      before do
        File.open(path, "wb") { |file|  file.write("line1\nline2\n") }
      end

      it "is the same with more content" do
        saved = sincedb_obj
        File.open(path, "ab") { |file|  file.write("LINE-A\nLINE-B\n") }
        st = File.stat(path)
        ino = FileWatch::Watch.inode(path, st)
        discovered = FileWatch::WatchedFile.new_ongoing(path, ino, st)

        expect(discovered.storage_key).to eq(saved.storage_key)
        expect([:same_more_content, :same_newer]).to include(subject.compare_path_inode_same(discovered, saved))
      end
    end

    context "when loading a legacy sincedb record" do
      let(:serialize_str) { "#{raw_inode} 0 0 #{position}" }
      it "is the same" do
        expect(sincedb_obj.storage_key).not_to eq(watched_obj.storage_key)
        expect(subject.compare_inode_same(watched_obj, sincedb_obj)).to eq(:legacy)
      end
    end
  end

  context "when a file path is reused for a different file" do
    let(:path)  { directory + "/afile.log" }

    before do
      File.open(path, "wb") { |file|  file.write("line1\nline2\n") }
    end

    it "is not the same - just has more content" do
      saved = sincedb_obj
      FileUtils.rm(path)
      File.open(path, "wb") { |file|  file.write("LINE-A\nLINE-B\n") }
      st = File.stat(path)
      ino = FileWatch::Watch.inode(path, st)
      discovered = FileWatch::WatchedFile.new_ongoing(path, ino, st)

      expect(discovered.storage_key).not_to eq(saved.storage_key)
      expect(subject.compare_path_same(discovered, saved)).to eq(:more_content)
    end
  end

  context "when a file is renamed after its sincedb record was written" do
    let(:path)  { directory + "/afile.log" }
    let(:bpath) { directory + "/bfile.log" }

    before do
      File.open(path, "wb") { |file|  file.write("line1\nline2\n" * 5000) }
    end

    context "when the file is unchanged" do
      it "is the same" do
        saved = sincedb_obj
        FileUtils.mv(path, bpath)
        st = File.stat(bpath)
        ino = FileWatch::Watch.inode(bpath, st)
        discovered = FileWatch::WatchedFile.new_ongoing(bpath, ino, st)

        expect(discovered.storage_key).not_to eq(saved.storage_key)
        expect(subject.compare_inode_same(discovered, saved)).to eq(:same)
      end
    end

    context "when the file is truncated" do
      it "is a different file" do
        saved = sincedb_obj
        FileUtils.mv(path, bpath)
        File.open(bpath, "wb") { |file|  file.write("") }
        st = File.stat(bpath)
        ino = FileWatch::Watch.inode(bpath, st)
        discovered = FileWatch::WatchedFile.new_ongoing(bpath, ino, st)

        expect(discovered.storage_key).not_to eq(saved.storage_key)
        expect(subject.compare_inode_same(discovered, saved)).to eq(:less_content)
        expect(st.size).to eq(0)
      end
    end

    context "when the file is appended after the rename" do
      it "is the same even when new content is written" do
        saved = sincedb_obj
        FileUtils.mv(path, bpath)
        File.open(bpath, "ab") { |file|  file.write("line3\nline4\n" * 50) }
        st = File.stat(bpath)
        ino = FileWatch::Watch.inode(bpath, st)
        discovered = FileWatch::WatchedFile.new_ongoing(bpath, ino, st)

        expect(discovered.storage_key).not_to eq(saved.storage_key)
        expect(subject.compare_inode_same(discovered, saved)).to eq(:same_more_content)
      end
    end
  end
end
