use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::Write;

const MAX_BUFFER_SIZE: usize = 100;

pub enum LogLevel
{
  Info,
  Warning,
  Error,
  Critical,
}

pub struct LogEntry
{
  pub level: LogLevel,
  pub message: String,
  pub timestamp: f64, // We can use std::time later
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
    let prefix = match level
    {
      LogLevel::Info => "[INFO]",
      LogLevel::Warning => "[WARN]",
      LogLevel::Error => "[ERRO]",
      LogLevel::Critical => "[CRIT]",
    };

    let entry_text = format!("{} {}\n", prefix, message);

    // 1. Terminal Output
    print!("{}", entry_text);

    // 2. In-Memory Ring Buffer (for In-Game Console)
    if self.buffer.len() >= MAX_BUFFER_SIZE
    {
      self.buffer.pop_front();
    }
    self.buffer.push_back(LogEntry {
      level,
      message: message.to_string(),
      timestamp: 0.0, // Placeholder
    });

    // 3. File Output
    let file_result = OpenOptions::new().create(true).append(true).open(&self.file_path);

    if let Ok(mut file) = file_result
    {
      let _ = file.write_all(entry_text.as_bytes());
    }
  }
}
