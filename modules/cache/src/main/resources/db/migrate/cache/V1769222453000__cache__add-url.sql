SET search_path TO ${cache}, extensions;

ALTER TABLE video_summaries ADD COLUMN url TEXT;
