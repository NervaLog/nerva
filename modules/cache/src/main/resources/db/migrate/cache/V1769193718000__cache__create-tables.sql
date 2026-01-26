SET SEARCH_PATH TO ${cache}, extensions;

CREATE TABLE IF NOT EXISTS video_summaries (
    video_id TEXT PRIMARY KEY,
    summary JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_video_summaries_created_at ON video_summaries (created_at);
