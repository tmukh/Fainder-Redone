use pyo3::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum Comparison {
    Lt, // <
    Le, // <=
    Gt, // >
    Ge, // >=
}

impl Comparison {
    pub(super) fn from_str(s: &str) -> PyResult<Self> {
        // Accept only the four documented operators. The previous substring
        // fallback (`s.contains("l") => Lt`, `s.contains("g") => Gt`) silently
        // mapped any string containing an "l" or "g" to Lt/Gt, which is
        // dangerous if a future query generator emits a slightly different
        // form ("leg", "leq", "ge ").
        match s {
            "lt" => Ok(Comparison::Lt),
            "le" => Ok(Comparison::Le),
            "gt" => Ok(Comparison::Gt),
            "ge" => Ok(Comparison::Ge),
            _ => Err(pyo3::exceptions::PyValueError::new_err(format!(
                "Invalid comparison operator: {} (expected one of: lt, le, gt, ge)",
                s
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum IndexMode {
    Precision,
    Recall,
}

impl IndexMode {
    pub(super) fn from_str(s: &str) -> PyResult<Self> {
        match s {
            "precision" => Ok(IndexMode::Precision),
            "recall" => Ok(IndexMode::Recall),
            _ => Err(pyo3::exceptions::PyValueError::new_err(format!(
                "Invalid index mode: {}",
                s
            ))),
        }
    }
}

pub(super) struct TypedQuery {
    pub percentile: f32,
    pub comparison: Comparison,
    pub reference: f64,
}
