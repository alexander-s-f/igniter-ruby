/// Binary framed WAL.
///
/// Record layout:
///   [4 bytes BE u32: body_len][body_len bytes: rmp-serde body][4 bytes BE u32: CRC32 of body]
use magnus::{Error, IntoValue, RArray, Ruby};
use std::cell::RefCell;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};

use crate::fact::{Fact, FactData};

struct FileBackendInner {
    path: String,
    writer: BufWriter<File>,
}

#[magnus::wrap(class = "Igniter::Store::FileBackend", free_immediately, size)]
pub struct FileBackend(RefCell<FileBackendInner>);

impl FileBackend {
    pub fn rb_new(path: String) -> Result<Self, Error> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| Error::new(magnus::exception::runtime_error(), e.to_string()))?;
        Ok(FileBackend(RefCell::new(FileBackendInner {
            path,
            writer: BufWriter::new(file),
        })))
    }

    pub fn rb_write_fact(&self, rb_fact: &Fact) -> Result<(), Error> {
        let body = rmp_serde::to_vec_named(&rb_fact.0)
            .map_err(|e| Error::new(magnus::exception::runtime_error(), e.to_string()))?;
        let crc = crc32fast::hash(&body);
        let mut inner = self.0.borrow_mut();
        inner.writer.write_all(&(body.len() as u32).to_be_bytes())
            .and_then(|_| inner.writer.write_all(&body))
            .and_then(|_| inner.writer.write_all(&crc.to_be_bytes()))
            .and_then(|_| inner.writer.flush())
            .map_err(|e| Error::new(magnus::exception::runtime_error(), e.to_string()))
    }

    pub fn rb_replay(&self) -> Result<RArray, Error> {
        let ruby = unsafe { Ruby::get_unchecked() };
        let path = self.0.borrow().path.clone();

        let mut file = File::open(&path)
            .map_err(|e| Error::new(magnus::exception::runtime_error(), e.to_string()))?;
        file.seek(SeekFrom::Start(0))
            .map_err(|e| Error::new(magnus::exception::runtime_error(), e.to_string()))?;

        let arr = RArray::new();
        loop {
            let mut len_buf = [0u8; 4];
            match file.read_exact(&mut len_buf) {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => return Err(Error::new(magnus::exception::runtime_error(), e.to_string())),
            }
            let body_len = u32::from_be_bytes(len_buf) as usize;

            let mut body = vec![0u8; body_len];
            if file.read_exact(&mut body).is_err() {
                break; // truncated record
            }

            let mut crc_buf = [0u8; 4];
            if file.read_exact(&mut crc_buf).is_err() {
                break;
            }
            if u32::from_be_bytes(crc_buf) != crc32fast::hash(&body) {
                break; // corrupted frame
            }

            let data: FactData = match rmp_serde::from_slice(&body) {
                Ok(d) => d,
                Err(_) => continue,
            };

            arr.push(Fact(data).into_value_with(&ruby))?;
        }
        Ok(arr)
    }

    pub fn rb_close(&self) -> Result<(), Error> {
        self.0.borrow_mut().writer.flush()
            .map_err(|e| Error::new(magnus::exception::runtime_error(), e.to_string()))
    }
}
