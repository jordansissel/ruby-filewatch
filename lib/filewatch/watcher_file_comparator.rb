module FileWatch
  class WatchedFileComparator
    def compare_inode_same(new_wf, existing)
      # different path
      # is it a copy?
      result = compare_path_inode_same(new_wf, existing)
      case result
      when :newer
        return :newer_more_content if new_wf.last_stat_size > existing.last_stat_size
        return :newer_less_content if new_wf.last_stat_size < existing.last_stat_size
        return :newer
      when :older
        return :older_more_content if new_wf.last_stat_size > existing.last_stat_size
        return :older_less_content if new_wf.last_stat_size < existing.last_stat_size
        return :older
      end
      result
    end

    def compare_path_same(new_wf, existing)
      # different inode
      # what has caused it to be on a new inode?
      compare_path_inode_same(new_wf, existing)
    end

    def compare_path_inode_same(new_wf, existing)
      return :same if existing.exactly_eq?(new_wf)

      if existing.created_at_and_stat_size_eq?(new_wf)
        if existing.bytes_read > new_wf.last_stat_size
          # a truncated file should have a newer created_at
          # jikes, must be bug, we overread
          existing.update_bytes_read(new_wf.last_stat_size)
        end
        return :same
      end

      #were they created at different times?
      if new_wf.created_at > existing.created_at
        return :newer
      end

      if new_wf.created_at < existing.created_at
        return :older
      end

      # they were created in the same second
      # new has more content
      if new_wf.last_stat_size > existing.last_stat_size
        # its the same file with more content
        return :same_more_content
      end

      # new has less content
      if new_wf.last_stat_size < existing.last_stat_size
        # its the same file with less content
        return :same_less_content
      end

      :unsure
    end

  end
end
