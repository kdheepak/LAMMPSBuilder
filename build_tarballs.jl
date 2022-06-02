# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg
using Base.BinaryPlatforms
module MPI

const tag_name = "mpi"

const augment = raw"""
    # Can't use Preferences since we might be running this very early with a non-existing Manifest
    MPIPreferences_UUID = Base.UUID("3da0fdf6-3ccc-4f1b-acd9-58baa6c99267")
    const preferences = Base.get_preferences(MPIPreferences_UUID)

    # Keep logic in sync with MPIPreferences.jl
    function augment_mpi!(platform)
        # Doesn't need to be `const` since we depend on MPIPreferences so we
        # invalidate the cache when it changes.
        binary = get(preferences, "binary", Sys.iswindows() ? "MicrosoftMPI_jll" : "MPICH_jll")

        abi = if binary == "system"
            let abi = get(preferences, "abi", nothing)
                if abi === nothing
                    error("MPIPreferences: Inconsistent state detected, binary set to system, but no ABI set.")
                else
                    abi
                end
            end
        elseif binary == "MicrosoftMPI_jll"
            "MicrosoftMPI"
        elseif binary == "MPICH_jll"
            "MPICH"
        elseif binary == "OpenMPI_jll"
            "OpenMPI"
        elseif binary == "MPItrampoline_jll"
            "MPItrampoline"
        else
            error("Unknown binary: $binary")
        end

        if !haskey(platform, "mpi")
            platform["mpi"] = abi
        end
        return platform
    end
"""

using BinaryBuilder, Pkg
using Base.BinaryPlatforms

mpi_abis = (
    ("MPICH", PackageSpec(name="MPICH_jll"), "", !Sys.iswindows) ,
    ("OpenMPI", PackageSpec(name="OpenMPI_jll"), "", !Sys.iswindows),
    ("MicrosoftMPI", PackageSpec(name="MicrosoftMPI_jll"), "", Sys.iswindows),
    ("MPItrampoline", PackageSpec(name="MPItrampoline_jll"), "", !Sys.iswindows)
)

function augment_platforms(platforms)
    all_platforms = AbstractPlatform[]
    dependencies = []
    for (abi, pkg, compat, f) in mpi_abis
        pkg_platforms = deepcopy(filter(f, platforms))
        foreach(pkg_platforms) do p
            p[tag_name] = abi
        end
        append!(all_platforms, pkg_platforms)
        push!(dependencies, Dependency(pkg; compat, platforms=pkg_platforms))
    end
    # NOTE: packages using this platform tag, must depend on MPIPreferences otherwise
    #       they will not be invalidated when the Preference changes.
    push!(dependencies, Dependency(PackageSpec(name="MPIPreferences", uuid="3da0fdf6-3ccc-4f1b-acd9-58baa6c99267"); compat="0.1"))
    return all_platforms, dependencies
end

end

name = "LAMMPS"
version = v"2.2.2" # Equivalent to 29Sep2021_update2

# Version table
# 1.0.0 -> https://github.com/lammps/lammps/releases/tag/stable_29Oct2020
# 2.0.0 -> https://github.com/lammps/lammps/releases/tag/stable_29Sep2021
# 2.2.0 -> https://github.com/lammps/lammps/releases/tag/stable_29Sep2021_update2

# Collection of sources required to complete build
sources = [
    GitSource("https://github.com/lammps/lammps.git", "7586adbb6a61254125992709ef2fda9134cfca6c")
]

# Bash recipe for building across all platforms
# LAMMPS DPD packages do not work on all platforms
script = raw"""
cd $WORKSPACE/srcdir/lammps/
mkdir build && cd build/
cmake -C ../cmake/presets/most.cmake -C ../cmake/presets/nolib.cmake ../cmake -DCMAKE_INSTALL_PREFIX=${prefix} \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLAMMPS_EXCEPTIONS=ON \
    -DPKG_MPI=ON \
    -DPKG_ML-SNAP=ON \
    -DPKG_ML-PACE=ON \
    -DPKG_DPD-BASIC=OFF \
    -DPKG_DPD-MESO=OFF \
    -DPKG_DPD-REACT=OFF \
    -DPKG_USER-MESODPD=OFF \
    -DPKG_USER-DPD=OFF \
    -DPKG_USER-SDPD=OFF \
    -DPKG_DPD-SMOOTH=OFF

make -j${nproc}
make install

if [[ "${target}" == *mingw* ]]; then
    cp *.dll ${prefix}/bin/
fi
"""

augment_platform_block = """
    using Base.BinaryPlatforms
    $(MPI.augment)
    function augment_platform!(platform::Platform)
        augment_mpi!(platform)
    end
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
# platforms = supported_platforms(; experimental=true)
platforms = supported_platforms()
platforms = filter(p -> !(Sys.isfreebsd(p) || libc(p) == "musl"), platforms)

# We need this since currently MPItrampoline_jll has a dependency on gfortran
platforms = expand_gfortran_versions(platforms)
# libgfortran3 does not support `!GCC$ ATTRIBUTES NO_ARG_CHECK`. (We
# could in principle build without Fortran support there.)
platforms = filter(p -> libgfortran_version(p) ≠ v"3", platforms)
# Compiler failure
filter!(p -> !(Sys.islinux(p) && arch(p) == "aarch64" && libc(p) =="glibc" && libgfortran_version(p) == v"4") , platforms)

platforms = expand_cxxstring_abis(platforms)

# The products that we will ensure are always built
products = [
    LibraryProduct("liblammps", :liblammps),
    ExecutableProduct("lmp", :lmp),
]

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency(PackageSpec(name="CompilerSupportLibraries_jll")),
]

all_platforms, platform_dependencies = MPI.augment_platforms(platforms)
append!(dependencies, platform_dependencies)

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, all_platforms, products, dependencies;
               julia_compat="1.6", preferred_gcc_version=v"8",
               augment_platform_block)
