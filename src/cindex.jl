module cindex

export cu_type, ty_kind, name, spelling, is_function, is_null,
       value, children, cu_file, resolve_type, return_type,
       tokenize
export CLType, CLCursor, CXString, CXTypeKind, CursorList, TokenList
export getindex, start, next, done, search, show, endof

import Base.getindex, Base.start, Base.next, Base.done, Base.search, Base.show
import Base.endof, Base.length

###############################################################################

# Name of the helper library
const libwci = :libwrapclang

###############################################################################

include("cindex/defs.jl")
include("cindex/types.jl")
include("cindex/base.jl")

###############################################################################

# Main entry point for parsing
# Returns root CXCursor in the TranslationUnit for a given header
#
# Required argument:
#   "header.h"          header file to parse
#
# Optional (keyword) arguments:
#   ClangIndex:         CXIndex pointer (pass to avoid re-allocation)
#   ClangDiagnostics:   Display Clang diagnostics
#   CPlusPlus:          Parse as C++
#   ClangArgs:          Compiler switches as string array, eg: ["-x", "c++", "-fno-elide-type"]
#   ParserFlags:        Bitwise OR of TranslationUnitFlags
#
function parse(header::String;
                ClangIndex                      = None,
                ClangDiagnostics::Bool          = false,
                CPlusPlus::Bool                 = false,
                ClangArgs                       = [""],
                ParserFlags                     = TranslationUnit_Flags.DetailedPreprocessingRecord |
                                                  TranslationUnit_Flags.SkipFunctionBodies)
    if (ClangIndex == None)
        ClangIndex = idx_create(0, (ClangDiagnostics ? 0 : 1))
    end
    if (CPlusPlus)
        push!(ClangOptions, ["-x", "c++"])
    end
    
    tu = tu_parse(ClangIndex, header, ClangArgs, length(ClangArgs),
                  C_NULL, 0, ParserFlags)
    if (tu == C_NULL)
        error("ParseTranslationUnit returned NULL; unable to create TranslationUnit")
    end
    
    return tu_cursor(tu)
end

###############################################################################
# Search function for CursorList
# Returns vector of CXCursors in CursorList matching predicate
#
# Required arguments:
#   CursorList      List to search
#   IsMatch(CXCursor)
#                   Predicate Function, accepting a CXCursor argument
#
function search(cl::CursorList, ismatch::Function)
    ret = CLCursor[]
    for cu in cl
        ismatch(cu) && push!(ret, cu)
    end
    ret
end
search(cu::CLCursor, ismatch::Function) = search(children(cu), ismatch)
search(cu::CLCursor, T::DataType) = search(cu, x->isa(x, T))
search(cu::CLCursor, name::ASCIIString) = search(cu, x->(cindex.spelling(x) == name))

###############################################################################
# Extended search function
# Returns a Dict{ DataType => CLCursor

function matchchildren(cu::CLCursor, types::Array{DataType,1})
    ret = { t => CLCursor[] for t in types}
    for child in children(cu)
        for t in types
            isa(child, t) && push!(ret[t], child)
        end
    end
    return ret
end

###############################################################################

# TODO: macro version should be more efficient.
anymatch(first, args...) = any({==(first, a) for a in args})

cu_type(c::CLCursor) = getCursorType(c)
ty_kind(c::CLType) = convert(Int, c.data[1].kind)
name(c::CLCursor) = getCursorDisplayName(c)
spelling(c::CLType) = getTypeKindSpelling(ty_kind(c))
spelling(c::CLCursor) = getCursorSpelling(c)
is_function(t::CLType) = (ty_kind(t) == TypeKind.FunctionProto)
is_null(c::CLCursor) = (Cursor_isNull(c) != 0)

function resolve_type(rt::CLType)
    # This helper attempts to work around some limitations of the
    # current libclang API.
    if ty_kind(rt) == cindex.TypeKind.Unexposed
        # try to resolve Unexposed type to cursor definition.
        rtdef_cu = cindex.getTypeDeclaration(rt)
        if (!is_null(rtdef_cu) && !isa(rtdef_cu, NoDeclFound))
            return cu_type(rtdef_cu)
        end
    end
    # otherwise, this will either be a builtin or unexposed
    # client needs to sort out.
    return rt
end

function return_type(c::Union(FunctionDecl, CXXMethod), resolve::Bool)
    if (resolve)
        return resolve_type( getCursorResultType(c) )
    else
        return getCursorResultType(c)
    end
end
return_type(c::CLCursor) = return_type(c, true)

function value(c::CLCursor)
    if !isa(c, EnumConstantDecl)
        error("Not a value cursor.")
    end
    t = cu_type(c)
    if anymatch(ty_kind(t), 
        TypeKind.IntType, TypeKind.Long, TypeKind.LongLong)
            return getEnumConstantDeclValue(c)
    end
    if anymatch(ty_kind(t),
        TypeKind.UInt, TypeKind.ULong, TypeKind.ULongLong)
            return getEnumConstantDeclUnsignedValue(c)
    end
end

tu_init(hdrfile::Any) = tu_init(hdrfile, 0, false, 0)
function tu_init(hdrfile::Any, diagnostics, cpp::Bool, opts::Int)
    idx = idx_create(0,diagnostics)
    tu = tu_parse(idx, hdrfile, (cpp ? ["-x", "c++"] : [""]), opts)
    return tu
end

###############################################################################
# Utility functions

tu_dispose(tu::CXTranslationUnit) = ccall( (:clang_disposeTranslationUnit, "libclang"), Void, (Ptr{Void},), tu)

function tu_cursor(tu::CXTranslationUnit)
    if (tu == C_NULL)
        error("Invalid TranslationUnit!")
    end
    getTranslationUnitCursor(tu)
end
 
tu_parse(CXIndex, source_filename::ASCIIString, 
                 cl_args::Array{ASCIIString,1}, num_clargs,
                 unsaved_files::CXUnsavedFile, num_unsaved_files,
                 options) =
    ccall( (:clang_parseTranslationUnit, "libclang"),
        CXTranslationUnit,
        (Ptr{Void}, Ptr{Uint8}, Ptr{Ptr{Uint8}}, Uint32, Ptr{Void}, Uint32, Uint32), 
            CXIndex, source_filename,
            cl_args, num_clargs,
            unsaved_files, num_unsaved_files, options)

idx_create() = idx_create(0,0)
idx_create(excludeDeclsFromPCH::Int, displayDiagnostics::Int) =
    ccall( (:clang_createIndex, "libclang"),
        CXTranslationUnit,
        (Int32, Int32),
        excludeDeclsFromPCH, displayDiagnostics)

#Typedef{"Pointer CXFile"} clang_getFile(CXTranslationUnit, const char *)
getFile(tu::CXTranslationUnit, file::ASCIIString) = 
    ccall( (:clang_getFile, "libclang"),
        CXFile,
        (Ptr{Void}, Ptr{Uint8}), tu, file)

function cl_create()
    ptr = ccall( (:wci_createCursorList, libwci),
        Ptr{Void},
        () )
    return CursorList(ptr,0)
end

function cl_dispose(cl::CursorList)
    ccall( (:wci_disposeCursorList, libwci),
        None,
        (Ptr{Void},), cl.ptr)
end

cl_size(cl::CursorList) = cl.size
cl_size(clptr::Ptr{Void}) =
    ccall( (:wci_sizeofCursorList, libwci),
        Int,
        (Ptr{Void},), clptr)

function getindex(cl::CursorList, clid::Int, default::UnionType)
    try
        getindex(cl, clid)
    catch
        return default
    end
end
function getindex(cl::CursorList, clid::Int)
    if (clid < 1 || clid > cl.size) error("Index out of range or empty list") end 
    cu = TmpCursor()
    ccall( (:wci_getCLCursor, libwci),
        Void,
        (Ptr{Void}, Ptr{Void}, Int), cu.data, cl.ptr, clid-1)
    return CXCursor(cu)
end

function children(cu::CLCursor)
    cl = cl_create() 
    ccall( (:wci_getChildren, libwci),
        Ptr{Void},
            (Ptr{CXCursor}, Ptr{Void}), cu.data, cl.ptr)
    size = cl_size(cl.ptr)
    return CursorList(cl.ptr,size)
end

function cu_file(cu::CLCursor)
    str = CXString()
    ccall( (:wci_getCursorFile, libwci),
        Void,
            (Ptr{Void}, Ptr{Void}), cu.data, str.data)
    return get_string(str)
end

start(cl::CursorList) = 1
done(cl::CursorList, i) = (i > cl.size)
next(cl::CursorList, i) = (cl[i], i+1)
length(cl::CursorList) = cl.size

################################################################################
# Tokenizer access
################################################################################

# Returns TokenList
function tokenize(cursor::CLCursor)
    tu = Cursor_getTranslationUnit(cursor)
    sourcerange = getCursorExtent(cursor)
    return cindex.tokenize(tu, sourcerange)
end

start(tl::TokenList) = 1
done(tl::TokenList, i) = (i > tl.size)
next(tl::TokenList, i) = (tl[i], i+1)
endof(tl::TokenList) = tl.size
length(tl::TokenList) = tl.size

function getindex(tl::TokenList, i::Int)
    if (i < 1 || i > tl.size) throw(BoundsError()) end

    c = CXToken(unsafe_load(tl.ptr, i))
    kind = c.data[1].int_data1
    spelling = cindex.getTokenSpelling(tl.tunit, c)

    if (kind == TokenKind.Punctuation)
        return Punctuation(spelling)
    elseif (kind == TokenKind.Keyword)
        return Keyword(spelling)
    elseif (kind == TokenKind.Identifier)
        return Identifier(spelling)
    elseif (kind == TokenKind.Literal)
        return Literal(spelling)
    elseif (kind == TokenKind.Comment)
        return Comment(spelling)
    end
end

################################################################################
# Display overrides
################################################################################

show(io::IO, tk::CLToken)   = print(io, typeof(tk), "(\"", tk.text, "\")")
show(io::IO, ty::CLType)    = print(io, "CLType (", typeof(ty), ") ")
show(io::IO, cu::CLCursor)    = print(io, "CLCursor (", typeof(cu), ") ", name(cu))

end # module
