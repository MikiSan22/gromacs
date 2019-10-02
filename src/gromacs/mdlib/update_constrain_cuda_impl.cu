/*
 * This file is part of the GROMACS molecular simulation package.
 *
 * Copyright (c) 2019, by the GROMACS development team, led by
 * Mark Abraham, David van der Spoel, Berk Hess, and Erik Lindahl,
 * and including many others, as listed in the AUTHORS file in the
 * top-level source directory and at http://www.gromacs.org.
 *
 * GROMACS is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 2.1
 * of the License, or (at your option) any later version.
 *
 * GROMACS is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with GROMACS; if not, see
 * http://www.gnu.org/licenses, or write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA.
 *
 * If you want to redistribute modifications to GROMACS, please
 * consider that scientific software is very special. Version
 * control is crucial - bugs must be traceable. We will be happy to
 * consider code for inclusion in the official distribution, but
 * derived work must not be called official GROMACS. Details are found
 * in the README & COPYING files - if they are missing, get the
 * official version at http://www.gromacs.org.
 *
 * To help us fund GROMACS development, we humbly ask that you cite
 * the research papers on the package. Check out http://www.gromacs.org.
 */
/*! \internal \file
 *
 * \brief Implements update and constraints class using CUDA.
 *
 * The class combines Leap-Frog integrator with LINCS and SETTLE constraints.
 *
 * \todo This class should take over the management of coordinates, velocities
 *       forces, virial, and PBC from its members (i.e. from Leap-Frog, LINCS
 *       and SETTLE).
 * \todo The computational procedures in members should be integrated to improve
 *       computational performance.
 *
 * \author Artem Zhmurov <zhmurov@gmail.com>
 *
 * \ingroup module_mdlib
 */
#include "gmxpre.h"

#include "update_constrain_cuda_impl.h"

#include <assert.h>
#include <stdio.h>

#include <cmath>

#include <algorithm>

#include "gromacs/gpu_utils/cudautils.cuh"
#include "gromacs/gpu_utils/devicebuffer.h"
#include "gromacs/gpu_utils/gputraits.cuh"
#include "gromacs/gpu_utils/vectype_ops.cuh"
#include "gromacs/mdlib/leapfrog_cuda.cuh"
#include "gromacs/mdlib/lincs_cuda.cuh"
#include "gromacs/mdlib/settle_cuda.cuh"
#include "gromacs/mdlib/update_constrain_cuda.h"

namespace gmx
{

void UpdateConstrainCuda::Impl::integrate(const real                        dt,
                                          const bool                        updateVelocities,
                                          const bool                        computeVirial,
                                          tensor                            virial,
                                          const bool                        doTempCouple,
                                          gmx::ArrayRef<const t_grp_tcstat> tcstat,
                                          const bool                        doPressureCouple,
                                          const float                       dtPressureCouple,
                                          const matrix                      velocityScalingMatrix)
{
    // Clearing virial matrix
    // TODO There is no point in having separate virial matrix for constraints
    clear_mat(virial);

    integrator_->integrate(d_x_, d_xp_, d_v_, d_f_, dt,
                           doTempCouple, tcstat,
                           doPressureCouple, dtPressureCouple, velocityScalingMatrix);
    lincsCuda_->apply(d_x_, d_xp_,
                      updateVelocities, d_v_, 1.0/dt,
                      computeVirial, virial);
    settleCuda_->apply(d_x_, d_xp_,
                       updateVelocities, d_v_, 1.0/dt,
                       computeVirial, virial);

    // scaledVirial -> virial (methods above returns scaled values)
    float scaleFactor = 0.5f/(dt*dt);
    for (int i = 0; i < DIM; i++)
    {
        for (int j = 0; j < DIM; j++)
        {
            virial[i][j] = scaleFactor*virial[i][j];
        }
    }

    // TODO: This should be eliminated
    cudaMemcpy(d_x_, d_xp_, numAtoms_*sizeof(float3), cudaMemcpyDeviceToDevice);

    return;
}

UpdateConstrainCuda::Impl::Impl(const t_inputrec  &ir,
                                const gmx_mtop_t  &mtop,
                                const void        *commandStream)
{
    commandStream != nullptr ? commandStream_ = *static_cast<const CommandStream*>(commandStream) : commandStream_ = nullptr;

    integrator_ = std::make_unique<LeapFrogCuda>(commandStream_);
    lincsCuda_  = std::make_unique<LincsCuda>(ir.nLincsIter, ir.nProjOrder, commandStream_);
    settleCuda_ = std::make_unique<SettleCuda>(mtop, commandStream_);

}

UpdateConstrainCuda::Impl::~Impl()
{
}

void UpdateConstrainCuda::Impl::set(DeviceBuffer<float>        d_x,
                                    DeviceBuffer<float>        d_v,
                                    const DeviceBuffer<float>  d_f,
                                    const t_idef              &idef,
                                    const t_mdatoms           &md,
                                    const int                  numTempScaleValues)
{
    GMX_ASSERT(d_x != nullptr, "Coordinates device buffer should not be null.");
    GMX_ASSERT(d_v != nullptr, "Velocities device buffer should not be null.");
    GMX_ASSERT(d_f != nullptr, "Forces device buffer should not be null.");

    d_x_ = reinterpret_cast<float3*>(d_x);
    d_v_ = reinterpret_cast<float3*>(d_v);
    d_f_ = reinterpret_cast<float3*>(d_f);

    numAtoms_ = md.nr;

    reallocateDeviceBuffer(&d_xp_, numAtoms_, &numXp_, &numXpAlloc_, nullptr);

    reallocateDeviceBuffer(&d_inverseMasses_, numAtoms_,
                           &numInverseMasses_, &numInverseMassesAlloc_, nullptr);

    // Integrator should also update something, but it does not even have a method yet
    integrator_->set(md, numTempScaleValues, md.cTC);
    lincsCuda_->set(idef, md);
    settleCuda_->set(idef, md);
}

void UpdateConstrainCuda::Impl::setPbc(const t_pbc *pbc)
{
    setPbcAiuc(pbc->ndim_ePBC, pbc->box, &pbcAiuc_);
    integrator_->setPbc(pbc);
    lincsCuda_->setPbc(pbc);
    settleCuda_->setPbc(pbc);
}

UpdateConstrainCuda::UpdateConstrainCuda(const t_inputrec  &ir,
                                         const gmx_mtop_t  &mtop,
                                         const void        *commandStream)
    : impl_(new Impl(ir, mtop, commandStream))
{
}

UpdateConstrainCuda::~UpdateConstrainCuda() = default;

void UpdateConstrainCuda::integrate(const real                        dt,
                                    const bool                        updateVelocities,
                                    const bool                        computeVirial,
                                    tensor                            virialScaled,
                                    const bool                        doTempCouple,
                                    gmx::ArrayRef<const t_grp_tcstat> tcstat,
                                    const bool                        doPressureCouple,
                                    const float                       dtPressureCouple,
                                    const matrix                      velocityScalingMatrix)
{
    impl_->integrate(dt, updateVelocities, computeVirial, virialScaled,
                     doTempCouple, tcstat,
                     doPressureCouple, dtPressureCouple, velocityScalingMatrix);
}

void UpdateConstrainCuda::set(DeviceBuffer<float>        d_x,
                              DeviceBuffer<float>        d_v,
                              const DeviceBuffer<float>  d_f,
                              const t_idef              &idef,
                              const t_mdatoms           &md,
                              const int                  numTempScaleValues)
{
    impl_->set(d_x, d_v, d_f, idef, md, numTempScaleValues);
}

void UpdateConstrainCuda::setPbc(const t_pbc *pbc)
{
    impl_->setPbc(pbc);
}

} //namespace gmx