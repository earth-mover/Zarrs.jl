# Mapping from zarrs_ffi data type enum values to Julia types
const ZARRS_DTYPE_TO_JULIA = Dict{Cint, DataType}(
    0  => Bool,       1  => Int8,       2  => Int16,      3  => Int32,
    4  => Int64,      5  => UInt8,      6  => UInt16,     7  => UInt32,
    8  => UInt64,     9  => Float16,    10 => Float32,    11 => Float64,
    12 => ComplexF32, 13 => ComplexF64,
)

# Mapping from Julia types to Zarr V3 data type strings
const JULIA_TO_ZARR_DTYPE = Dict{DataType, String}(
    Bool       => "bool",
    Int8       => "int8",       Int16   => "int16",
    Int32      => "int32",      Int64   => "int64",
    UInt8      => "uint8",      UInt16  => "uint16",
    UInt32     => "uint32",     UInt64  => "uint64",
    Float16    => "float16",    Float32 => "float32",
    Float64    => "float64",
    ComplexF32 => "complex64",  ComplexF64 => "complex128",
)

# Mapping from Julia types to NumPy dtype strings (for V2 metadata)
const JULIA_TO_NUMPY_DTYPE = Dict{DataType, String}(
    Bool       => "|b1",
    Int8       => "|i1",       Int16   => "<i2",
    Int32      => "<i4",       Int64   => "<i8",
    UInt8      => "|u1",       UInt16  => "<u2",
    UInt32     => "<u4",       UInt64  => "<u8",
    Float16    => "<f2",       Float32 => "<f4",
    Float64    => "<f8",
    ComplexF32 => "<c8",       ComplexF64 => "<c16",
)

"""
    numpy_dtype_str(T::DataType) -> String

Return the NumPy-style dtype string for Julia type `T` (for V2 metadata).
"""
numpy_dtype_str(T::DataType) = JULIA_TO_NUMPY_DTYPE[T]
