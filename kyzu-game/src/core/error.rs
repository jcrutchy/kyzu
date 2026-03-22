#[derive(Debug)]
pub enum KyzuError
{
  ConfigLoad(String),
  IO(String),
  Gpu(String),
  Window(String),
  Bake(String),
}

impl std::fmt::Display for KyzuError
{
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result
  {
    match self
    {
      KyzuError::ConfigLoad(msg) => write!(f, "Configuration Error: {}", msg),
      KyzuError::IO(msg) => write!(f, "I/O Error: {}", msg),
      KyzuError::Gpu(msg) => write!(f, "GPU Error: {}", msg),
      KyzuError::Window(msg) => write!(f, "Windowing Error: {}", msg),
      KyzuError::Bake(msg) => write!(f, "Bake Engine Error: {}", msg),
    }
  }
}

// This allows us to use '?' easily
impl std::error::Error for KyzuError {}
