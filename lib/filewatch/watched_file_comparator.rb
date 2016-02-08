module FileWatch
  class WatchedFileComparator
    def compare_inode_same(new_wf, existing)
      # is existing built from a legacy sincedb line?
      # we don't have much information
      if existing.created_at == 0.0
        return :legacy
      end
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
      # file was deleted and rewritten perhaps?
      compare_path_inode_same(new_wf, existing)
    end

    def compare_path_inode_same(new_wf, existing)
      if existing.equivalent?(new_wf)
        if existing.bytes_read > new_wf.last_stat_size &&
            existing.storage_key == new_wf.storage_key
          # jikes, must be bug, we overread
          # but only if the path and inode are the same
          existing.update_bytes_read(new_wf.last_stat_size)
        end
        if existing.content_read_equal?(new_wf)
          return :same
        end
        return :similar
      end

      # were they created at different times?
      if new_wf.created_at > existing.created_at
        if existing.content_read_equal?(new_wf)
          return :same_newer
        end
        return :newer
      end

      if new_wf.created_at < existing.created_at
        if existing.content_read_equal?(new_wf)
          return :same_older
        end
        return :older
      end

      # they were created in the same second
      if new_wf.last_stat_size > existing.last_stat_size
        # new has more content
        # is it the same file with more content?
        if existing.content_read_equal?(new_wf)
          return :same_more_content
        end
        return :more_content
      end

      if new_wf.last_stat_size < existing.last_stat_size
        # new has less content
        # is it the same file with less content
        if existing.content_read_equal?(new_wf)
          return :same_less_content
        end
        return :less_content
      end

      :unsure
    end
  end
end
