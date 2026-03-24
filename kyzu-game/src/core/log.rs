use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_BUFFER_SIZE: usize = 100;

pub enum LogLevel
{
  Info,
  Warning,
  Error,
  Critical,
  Debug,
}

pub struct LogEntry
{
  pub level: LogLevel,
  pub message: String,
  pub timestamp: SystemTime,
}

pub struct Logger
{
  pub file_path: String,
  pub buffer: VecDeque<LogEntry>,
}

impl Logger
{
  pub fn new(path: &str) -> Self
  {
    Self { file_path: path.to_string(), buffer: VecDeque::with_capacity(MAX_BUFFER_SIZE) }
  }

  pub fn emit(&mut self, level: LogLevel, message: &str)
  {
    let now = SystemTime::now();
    let duration = now.duration_since(UNIX_EPOCH).unwrap_or_default();
    let total_seconds = duration.as_secs();

    // Basic math to get HH:MM:SS (UTC)
    let seconds = total_seconds % 60;
    let minutes = (total_seconds / 60) % 60;
    let hours = (total_seconds / 3600) % 24;

    let time_str = format!("{:02}:{:02}:{:02}", hours, minutes, seconds);

    let prefix = match level
    {
      LogLevel::Info => "[INFO]",
      LogLevel::Warning => "[WARN]",
      LogLevel::Error => "[ERRO]",
      LogLevel::Critical => "[CRIT]",
      LogLevel::Debug => "[DEBUG]",
    };

    let entry_text = format!("{} {} {}\n", time_str, prefix, message);

    // 1. Terminal Output
    print!("{}", entry_text);

    // 2. In-Memory Ring Buffer (for In-Game Console)
    if self.buffer.len() >= MAX_BUFFER_SIZE
    {
      self.buffer.pop_front();
    }
    self.buffer.push_back(LogEntry { level, message: message.to_string(), timestamp: now });

    // 3. File Output
    let file_result = OpenOptions::new().create(true).append(true).open(&self.file_path);

    if let Ok(mut file) = file_result
    {
      let _ = file.write_all(entry_text.as_bytes());
    }
  }

  pub fn info(&mut self, msg: &str)
  {
    self.emit(LogLevel::Info, msg);
  }
  pub fn error(&mut self, msg: &str)
  {
    self.emit(LogLevel::Error, msg);
  }
}
