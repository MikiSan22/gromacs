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
/*! \libinternal \file
 *
 * \brief Declaration of high-level functions of CUDA implementation of update and constrain class.
 *
 * \todo This should only list interfaces needed for libgromacs clients (e.g.
 *       management of coordinates, velocities and forces should not be here).
 * \todo Change "cuda" suffix to "gpu"
 *
 * \author Artem Zhmurov <zhmurov@gmail.com>
 *
 * \ingroup module_mdlib
 * \inlibraryapi
 */
#ifndef GMX_MDLIB_UPDATE_CONSTRAIN_CUDA_H
#define GMX_MDLIB_UPDATE_CONSTRAIN_CUDA_H

#include "gromacs/gpu_utils/devicebuffer_datatype.h"
#include "gromacs/mdtypes/group.h"
#include "gromacs/utility/arrayref.h"
#include "gromacs/utility/classhelpers.h"

struct gmx_mtop_t;
struct t_idef;
struct t_inputrec;
struct t_mdatoms;
struct t_pbc;

namespace gmx
{

class UpdateConstrainCuda
{

    public:
        /*! \brief Create Update-Constrain object.
         *
         * \param[in] ir             Input record data: LINCS takes number of iterations and order of
         *                           projection from it.
         * \param[in] mtop           Topology of the system: SETTLE gets the masses for O and H atoms
         *                           and target O-H and H-H distances from this object.
         * \param[in] commandStream  GPU stream to use. Can be nullptr.
         */
        UpdateConstrainCuda(const t_inputrec  &ir,
                            const gmx_mtop_t  &mtop,
                            const void        *commandStream);

        ~UpdateConstrainCuda();

        /*! \brief Integrate
         *
         * This will extract temperature scaling factors from tcstat, transform them into the plain
         * array and call the normal integrate method.
         *
         * \param[in]  dt                     Timestep.
         * \param[in]  updateVelocities       If the velocities should be constrained.
         * \param[in]  computeVirial          If virial should be updated.
         * \param[out] virial                 Place to save virial tensor.
         * \param[in]  doTempCouple           If the temperature coupling should be performed.
         * \param[in]  tcstat                 Temperature coupling data.
         * \param[in]  doPressureCouple       If the temperature coupling should be applied.
         * \param[in]  dtPressureCouple       Period between pressure coupling steps
         * \param[in]  velocityScalingMatrix  Parrinello-Rahman velocity scaling matrix
         */
        void integrate(real                              dt,
                       bool                              updateVelocities,
                       bool                              computeVirial,
                       tensor                            virial,
                       bool                              doTempCouple,
                       gmx::ArrayRef<const t_grp_tcstat> tcstat,
                       bool                              doPressureCouple,
                       float                             dtPressureCouple,
                       const matrix                      velocityScalingMatrix);

        /*! \brief Set the pointers and update data-structures (e.g. after NB search step).
         *
         * \param[in,out]  d_x                 Device buffer with coordinates.
         * \param[in,out]  d_v                 Device buffer with velocities.
         * \param[in]      d_f                 Device buffer with forces.
         * \param[in]      idef                System topology
         * \param[in]      md                  Atoms data.
         * \param[in]      numTempScaleValues  Number of temperature scaling groups. Zero for no temperature scaling.
         */
        void set(DeviceBuffer<float>  d_x,
                 DeviceBuffer<float>  d_v,
                 DeviceBuffer<float>  d_f,
                 const t_idef        &idef,
                 const t_mdatoms     &md,
                 int                  numTempScaleValues);

        /*! \brief
         * Update PBC data.
         *
         * Converts PBC data from t_pbc into the PbcAiuc format and stores the latter.
         *
         * \param[in] pbc The PBC data in t_pbc format.
         */
        void setPbc(const t_pbc *pbc);


    private:
        class Impl;
        gmx::PrivateImplPointer<Impl> impl_;

};

} //namespace gmx

#endif