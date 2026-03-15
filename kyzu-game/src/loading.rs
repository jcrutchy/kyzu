use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

// ──────────────────────────────────────────────────────────────
//   A single line in the console log
// ──────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct LogLine
{
  pub kind: LineKind,
  pub message: String,
}

#[derive(Clone, PartialEq)]
pub enum LineKind
{
  Info,
  Done,
  Wait,
  Progress,
  Error,
}

// ──────────────────────────────────────────────────────────────
//   Shared bake state — written by background thread,
//   read by the render thread
// ──────────────────────────────────────────────────────────────

#[derive(Default)]
pub struct BakeState
{
  pub lines: Vec<LogLine>,
  pub progress: u32, // 0-100
  pub finished: bool,
  pub _failed: bool,
}

// ──────────────────────────────────────────────────────────────
//   BakeProcess — spawns kyzu-bake and reads its stdout
// ──────────────────────────────────────────────────────────────

pub struct BakeProcess
{
  pub state: Arc<Mutex<BakeState>>,
}

impl BakeProcess
{
  pub fn spawn(bake_exe: &str) -> anyhow::Result<Self>
  {
    let mut child: Child =
      Command::new(bake_exe).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;

    let state = Arc::new(Mutex::new(BakeState::default()));
    let state_clone = state.clone();

    let stdout = child.stdout.take().unwrap();

    thread::spawn(move || {
      let reader = BufReader::new(stdout);

      for line in reader.lines()
      {
        let line = match line
        {
          Ok(l) => l,
          Err(_) => break,
        };

        let (kind, message) = parse_line(&line);

        let mut s = state_clone.lock().unwrap();

        if kind == LineKind::Progress
        {
          let parts: Vec<&str> = line.splitn(3, ' ').collect();
          if parts.len() >= 2
          {
            if let Ok(pct) = parts[1].parse::<u32>()
            {
              s.progress = pct;
            }
          }
          // Also add to log so scroll area shows history
          if let Some(msg) = line.strip_prefix("[PROGRESS] ")
          {
            s.lines.push(LogLine { kind: LineKind::Progress, message: msg.to_string() });
          }
        }
        else
        {
          s.lines.push(LogLine { kind, message });
        }
      }

      // Wait for process to exit
      let _ = child.wait();

      let mut s = state_clone.lock().unwrap();
      s.finished = true;
    });

    Ok(Self { state })
  }

  pub fn progress(&self) -> u32
  {
    self.state.lock().unwrap().progress
  }

  pub fn finished(&self) -> bool
  {
    self.state.lock().unwrap().finished
  }

  pub fn lines(&self) -> Vec<LogLine>
  {
    self.state.lock().unwrap().lines.clone()
  }
}

// ──────────────────────────────────────────────────────────────
//   Parse a structured line from kyzu-bake stdout
// ──────────────────────────────────────────────────────────────

fn parse_line(line: &str) -> (LineKind, String)
{
  if let Some(msg) = line.strip_prefix("[DONE] ")
  {
    (LineKind::Done, msg.to_string())
  }
  else if let Some(msg) = line.strip_prefix("[WAIT] ")
  {
    (LineKind::Wait, msg.to_string())
  }
  else if let Some(msg) = line.strip_prefix("[INFO] ")
  {
    (LineKind::Info, msg.to_string())
  }
  else if let Some(msg) = line.strip_prefix("[ERROR] ")
  {
    (LineKind::Error, msg.to_string())
  }
  else if line.starts_with("[PROGRESS] ")
  {
    (LineKind::Progress, line.to_string())
  }
  else
  {
    (LineKind::Info, line.to_string())
  }
}
