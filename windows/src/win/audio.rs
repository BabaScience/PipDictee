//! Microphone recording with cpal (WASAPI), down-mixed to mono and resampled to the 16 kHz Whisper expects.

use crate::store::log;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::Instant;

pub struct Recorder {
    _stream: cpal::Stream,
    buf: Arc<Mutex<Vec<f32>>>,
    rate: u32,
    started: Instant,
}

pub struct Take { pub samples: Vec<f32>, pub peak_db: f32, pub seconds: f64 }

fn on_error(e: cpal::StreamError) { log(&format!("audio error: {e}")); }

/// The level of the last audio block, for the pill's waveform and the setup's mic check (f32 bits).
static LEVEL: AtomicU32 = AtomicU32::new(0);
static PEAK: AtomicU32 = AtomicU32::new(0);

/// (level 0…1 for display, peak in dBFS) of the most recent audio block.
pub fn level() -> (f32, f32) {
    let avg = f32::from_bits(LEVEL.load(Relaxed));
    let peak = f32::from_bits(PEAK.load(Relaxed));
    let db = |x: f32| if x > 0.0 { 20.0 * x.log10() } else { -160.0 };
    (((db(avg) + 55.0) / 40.0).clamp(0.0, 1.0), db(peak))
}
pub fn reset_level() { LEVEL.store(0, Relaxed); PEAK.store(0, Relaxed); }

/// The name of the microphone Windows will use, shown in setup so a wrong input is easy to spot.
pub fn input_name() -> Option<String> { cpal::default_host().default_input_device().and_then(|d| d.name().ok()) }

fn push(buf: &Mutex<Vec<f32>>, channels: usize, frames: impl Iterator<Item = f32>) {
    let mut v = buf.lock().unwrap();
    let start = v.len();
    let mut acc = 0.0; let mut n = 0;
    for s in frames {
        acc += s; n += 1;
        if n == channels { v.push(acc / channels as f32); acc = 0.0; n = 0; }
    }
    let block = &v[start..];
    if !block.is_empty() {
        let (sum, peak) = block.iter().fold((0f32, 0f32), |(s, p), x| (s + x.abs(), p.max(x.abs())));
        LEVEL.store((sum / block.len() as f32).to_bits(), Relaxed);
        PEAK.store(peak.to_bits(), Relaxed);
    }
}

impl Recorder {
    pub fn start() -> Result<Recorder, String> {
        let dev = cpal::default_host().default_input_device().ok_or("no microphone")?;
        let cfg = dev.default_input_config().map_err(|e| e.to_string())?;
        let (rate, ch, fmt) = (cfg.sample_rate().0, cfg.channels() as usize, cfg.sample_format());
        let buf = Arc::new(Mutex::new(Vec::with_capacity(rate as usize * 60)));
        let b = buf.clone();
        let sc: cpal::StreamConfig = cfg.into();
        let stream = match fmt {
            SampleFormat::F32 => dev.build_input_stream(&sc, move |d: &[f32], _| push(&b, ch, d.iter().copied()), on_error, None),
            SampleFormat::I16 => dev.build_input_stream(&sc, move |d: &[i16], _| push(&b, ch, d.iter().map(|&s| s as f32 / 32768.0)), on_error, None),
            SampleFormat::U16 => dev.build_input_stream(&sc, move |d: &[u16], _| push(&b, ch, d.iter().map(|&s| (s as f32 - 32768.0) / 32768.0)), on_error, None),
            f => return Err(format!("unsupported audio format: {f:?}")),
        }.map_err(|e| e.to_string())?;
        stream.play().map_err(|e| e.to_string())?;
        Ok(Recorder { _stream: stream, buf, rate, started: Instant::now() })
    }

    /// Stops the microphone (the stream is dropped) and returns 16 kHz mono samples.
    pub fn finish(self) -> Take {
        let seconds = self.started.elapsed().as_secs_f64();
        let raw = std::mem::take(&mut *self.buf.lock().unwrap());
        let peak = raw.iter().fold(0f32, |m, s| m.max(s.abs()));
        let peak_db = if peak > 0.0 { 20.0 * peak.log10() } else { -160.0 };
        Take { samples: resample(&raw, self.rate, 16_000), peak_db, seconds }
    }
}

fn resample(x: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || x.is_empty() { return x.to_vec(); }
    let n = (x.len() as u64 * to as u64 / from as u64) as usize;
    let step = from as f64 / to as f64;
    (0..n).map(|i| {
        let p = i as f64 * step; let j = p as usize; let f = (p - j as f64) as f32;
        let a = x[j]; let b = *x.get(j + 1).unwrap_or(&a);
        a + (b - a) * f
    }).collect()
}

pub fn temp_wav() -> PathBuf {
    std::env::temp_dir().join(format!("pip-dictee-{}.wav", chrono::Utc::now().timestamp_millis()))
}

pub fn write_wav(path: &Path, samples: &[f32]) -> Result<(), String> {
    let spec = hound::WavSpec { channels: 1, sample_rate: 16_000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
    let mut w = hound::WavWriter::create(path, spec).map_err(|e| e.to_string())?;
    for s in samples { w.write_sample((s.clamp(-1.0, 1.0) * 32767.0) as i16).map_err(|e| e.to_string())?; }
    w.finalize().map_err(|e| e.to_string())
}

/// Recordings left in the temporary folder by a crash.
pub fn remove_leftovers() {
    if let Ok(rd) = std::fs::read_dir(std::env::temp_dir()) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("pip-dictee") && n.ends_with(".wav") { let _ = std::fs::remove_file(e.path()); }
        }
    }
}
