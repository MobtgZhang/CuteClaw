/** 对齐 config.ApiConfigJson / docs/format.md */

export interface ApiHeader {
  name: string;
  value: string;
}

export interface ApiConfigJson {
  schema_version: number;
  provider: string;
  api_base: string;
  api_key_file: string;
  api_key_env: string;
  model: string;
  connect_timeout_sec: number;
  read_timeout_sec: number;
  extra_headers: ApiHeader[];
}
