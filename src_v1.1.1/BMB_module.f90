MODULE BMB_module

  USE mpi
  USE configuration_module,          ONLY: dp, C
  USE parallel_module,               ONLY: par, sync, ierr, cerr, write_to_memory_log, &
                                           allocate_shared_int_0D, allocate_shared_dp_0D, &
                                           allocate_shared_int_1D, allocate_shared_dp_1D, &
                                           allocate_shared_int_2D, allocate_shared_dp_2D, &
                                           allocate_shared_int_3D, allocate_shared_dp_3D, &
                                           deallocate_shared
  USE data_types_module,             ONLY: type_mesh, type_ice_model, type_subclimate_region, type_BMB_model, &
                                           type_remapping
  USE netcdf_module,                 ONLY: debug, write_to_debug_file
  USE forcing_module,                ONLY: forcing
  USE parameters_module,             ONLY: pi, T0, L_fusion, sec_per_year, seawater_density, ice_density
  USE mesh_mapping_module,           ONLY: reallocate_field_dp

  IMPLICIT NONE
    
CONTAINS

  ! Run the SMB model on the region mesh
  SUBROUTINE run_BMB_model( mesh, ice, climate, BMB, region_name)
    ! Calculate mean ocean temperature (saved in "climate") and basal mass balance
    
    IMPLICIT NONE
    
    ! In/output variables
    TYPE(type_mesh),                     INTENT(IN)    :: mesh 
    TYPE(type_ice_model),                INTENT(IN)    :: ice
    TYPE(type_subclimate_region),        INTENT(INOUT) :: climate
    TYPE(type_BMB_model),                INTENT(INOUT) :: BMB
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    
    ! Local variables
    CHARACTER(LEN=64), PARAMETER                       :: routine_name = 'run_BMB_model'
    INTEGER                                            :: n1, n2
    INTEGER                                            :: vi
    REAL(dp)                                           :: BMB_shelf                             ! Sub-shelf melt rate for non-exposed shelf  [m/year]
    REAL(dp)                                           :: BMB_shelf_exposed                     ! Sub-shelf melt rate for exposed shelf      [m/year]
    REAL(dp)                                           :: BMB_deepocean                         ! Sub-shelf melt rate for deep-ocean areas   [m/year]
    REAL(dp)                                           :: w_ins, w_PD, w_warm, w_cold, w_deep, w_expo, weight
    REAL(dp)                                           :: T_freeze                              ! Freezing temperature at the base of the shelf (Celcius)
    REAL(dp)                                           :: water_depth
    REAL(dp), PARAMETER                                :: cp0        = 3974._dp                 ! specific heat capacity of the ocean mixed layer (J kg-1 K-1) 
    REAL(dp), PARAMETER                                :: gamma_T    = 1.0E-04_dp               ! Thermal exchange velocity (m s-1)
    
    n1 = par%mem%n
    
    ! Exceptions for benchmark experiments
    IF (C%do_benchmark_experiment) THEN
      IF (C%choice_benchmark_experiment == 'EISMINT_1' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_2' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_3' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_4' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_5' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_6' .OR. &
          C%choice_benchmark_experiment == 'Halfar' .OR. &
          C%choice_benchmark_experiment == 'Bueler' .OR. &
          C%choice_benchmark_experiment == 'SSA_icestream' .OR. &
          C%choice_benchmark_experiment == 'MISMIP_mod') THEN
        BMB%BMB( mesh%v1:mesh%v2) = 0._dp
        CALL sync
        RETURN
      ELSE
        IF (par%master) WRITE(0,*) '  ERROR: benchmark experiment "', TRIM(C%choice_benchmark_experiment), '" not implemented in run_BMB_model!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
    END IF ! IF (C%do_benchmark_experiment) THEN
      
    ! Initialise everything at zero
    BMB%BMB(       mesh%v1:mesh%v2) = 0._dp
    BMB%BMB_sheet( mesh%v1:mesh%v2) = 0._dp
    BMB%BMB_shelf( mesh%v1:mesh%v2) = 0._dp
    BMB%sub_angle( mesh%v1:mesh%v2) = 360._dp
    BMB%dist_open( mesh%v1:mesh%v2) = 0._dp
    w_ins                             = 0._dp
    weight                            = 0._dp
    w_PD                              = 0._dp
    w_warm                            = 0._dp
    w_cold                            = 0._dp
    w_deep                            = 0._dp
    w_expo                            = 0._dp
    BMB_shelf                         = 0._dp
    BMB_shelf_exposed                 = 0._dp
    BMB_deepocean                     = 0._dp
    
    ! Find the "subtended angle" and distance-to-open-ocean of all shelf pixels
    DO vi = mesh%v1, mesh%v2
      CALL calculate_sub_angle_dist_open( mesh, ice, vi, BMB%sub_angle( vi), BMB%dist_open( vi))
    END DO
    CALL sync
    
    ! Find the weight from insolation
    IF (region_name == 'NAM' .OR. region_name == 'EAS' .OR. region_name == 'GRL') THEN
      w_ins = MAX(0._dp, (climate%Q_TOA_jun_65N - 462.29_dp) / 40._dp)
    ELSEIF (region_name == 'ANT') THEN
      w_ins = MAX(0._dp, (climate%Q_TOA_jan_80S - 532.19_dp) / 40._dp)
    END IF
    
    ! Determine mean ocean temperature and basal melt rates for deep ocean and exposed shelves
    ! ========================================================================================
    
    IF (C%choice_ocean_temperature_model == 'fixed') THEN
      ! Use present-day values
      
      climate%T_ocean_mean = BMB%T_ocean_mean_PD
      BMB_deepocean        = BMB%BMB_deepocean_PD
      BMB_shelf_exposed    = BMB%BMB_shelf_exposed_PD
      
    ELSEIF (C%choice_ocean_temperature_model == 'scaled') THEN
      ! Scale between config values of mean ocean temperature and basal melt rates for PD, cold, and warm climates.
    
      ! Determine weight for scaling between different ocean temperatures
      IF (C%choice_forcing_method == 'CO2_direct') THEN
      
        ! Use the prescribed CO2 record as a glacial index
        IF (forcing%CO2_obs > 280._dp) THEN
          ! Warmer than present, interpolate between "PD" and "warm", assuming "warm" means 400 ppmv
          weight = 2._dp - MAX( 0._dp,   MIN(1.25_dp, ((400._dp - forcing%CO2_obs) / (400._dp - 280._dp) + (3.00_dp - forcing%d18O_obs) / (3.00_dp - 3.23_dp)) / 2._dp )) + w_ins
        ELSE
          ! Colder than present, interpolate between "PD" and "cold", assuming "cold" means 190 ppmv
          weight = 1._dp - MAX(-0.25_dp, MIN(1._dp,   ((280._dp - forcing%CO2_obs) / (280._dp - 190._dp) + (3.23_dp - forcing%d18O_obs) / (3.23_dp - 4.95_dp)) / 2._dp )) + w_ins
        END IF
        
      ELSEIF (C%choice_forcing_method == 'd18O_inverse_CO2') THEN
      
        ! Use modelled CO2 as a glacial index
        IF (forcing%CO2_obs > 280._dp) THEN
          ! Warmer than present, interpolate between "PD" and "warm", assuming "warm" means 400 ppmv
          weight = 2._dp - MAX( 0._dp,   MIN(1.25_dp, ((400._dp - forcing%CO2_mod) / (400._dp - 280._dp) + (3.00_dp - forcing%d18O_obs) / (3.00_dp - 3.23_dp)) / 2._dp )) + w_ins
        ELSE
          ! Colder than present, interpolate between "PD" and "cold", assuming "cold" means 190 ppmv
          weight = 1._dp - MAX(-0.25_dp, MIN(1._dp,   ((280._dp - forcing%CO2_mod) / (280._dp - 190._dp) + (3.23_dp - forcing%d18O_obs) / (3.23_dp - 4.95_dp)) / 2._dp )) + w_ins
        END IF
        
      ELSEIF (C%choice_forcing_method == 'd18O_inverse_dT_glob') THEN
      
        ! Use modelled global mean annual temperature change as a glacial index
        weight = MAX(0._dp, MIN(2._dp, 1._dp + forcing%dT_glob/12._dp + w_ins))
        
      ELSE ! IF (C%choice_forcing_method == 'CO2_direct') THEN
        WRITE(0,*) '  ERROR: forcing method "', TRIM(C%choice_forcing_method), '" not implemented in run_BMB_model!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF ! IF (C%choice_forcing_method == 'CO2_direct') THEN
      
      IF (weight < 1._dp) THEN
        w_PD   = weight
        w_cold = 1._dp - w_PD
        w_warm = 0._dp
      ELSE
        w_PD   = 2._dp - weight
        w_warm = 1._dp - w_PD
        w_cold = 0._dp
      END IF
      
      climate%T_ocean_mean = w_PD * BMB%T_ocean_mean_PD      + w_warm * BMB%T_ocean_mean_warm      + w_cold * BMB%T_ocean_mean_cold
      BMB_deepocean        = w_PD * BMB%BMB_deepocean_PD     + w_warm * BMB%BMB_deepocean_warm     + w_cold * BMB%BMB_deepocean_cold
      BMB_shelf_exposed    = w_PD * BMB%BMB_shelf_exposed_PD + w_warm * BMB%BMB_shelf_exposed_warm + w_cold * BMB%BMB_shelf_exposed_cold
      
    ELSE ! IF (C%choice_ocean_temperature_model == 'fixed') THEN
      WRITE(0,*) '  ERROR: choice_ocean_temperature_model "', TRIM(C%choice_ocean_temperature_model), '" not implemented in run_BMB_model!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF ! IF (C%choice_ocean_temperature_model == 'fixed') THEN
    
    ! Use the (interpolated, spatially uniform) ocean temperature and the subtended angle + distance-to-open-ocean
    ! to calculate sub-shelf melt rates using the parametrisation from Martin et al., 2011
    ! ====================================================================================
    
    DO vi = mesh%v1, mesh%v2
    
      IF (ice%mask_shelf( vi) == 1) THEN
        ! Sub-shelf melt

        ! Freezing temperature at the bottom of the ice shelves, scaling with depth below water level
        T_freeze = 0.0939_dp - 0.057_dp * 35._dp - 7.64E-04_dp * ice%Hi( vi) * ice_density / seawater_density

        ! Sub-shelf melt rate for non-exposed shelves (Martin, TC, 2011) - melt values, when T_ocean > T_freeze.
        BMB_shelf   = seawater_density * cp0 * sec_per_year * gamma_T * BMB%subshelf_melt_factor * &
                   (climate%T_ocean_mean - T_freeze) / (L_fusion * ice_density)

      ELSE
        BMB_shelf = 0._dp
      END IF

      IF (ice%mask_shelf( vi) == 1 .OR. ice%mask_ocean( vi) == 1) THEN
      
        water_depth = ice%SL( vi) - ice%Hb( vi)
        w_deep = MAX(0._dp, MIN(1._dp, (water_depth - BMB%deep_ocean_threshold_depth) / 200._dp))
        w_expo = MAX(0._dp, MIN(1._dp, (BMB%sub_angle( vi) - 80._dp)/30._dp)) * EXP(-BMB%dist_open( vi) / 100000._dp)
        
        BMB%BMB_shelf( vi) = (w_deep * BMB_deepocean) + (1._dp - w_deep) * (w_expo * BMB_shelf_exposed + (1._dp - w_expo) * BMB_shelf)
        
      ELSE  
        BMB%BMB_shelf( vi) = 0._dp
      END IF

    END DO
    CALL sync
    
    ! Add sheet and shelf melt together
    BMB%BMB( mesh%v1:mesh%v2) = BMB%BMB_sheet( mesh%v1:mesh%v2) + BMB%BMB_shelf( mesh%v1:mesh%v2)
    CALL sync
    
    n2 = par%mem%n
    !CALL write_to_memory_log( routine_name, n1, n2)
          
  END SUBROUTINE run_BMB_model
  
  SUBROUTINE calculate_sub_angle_dist_open( mesh, ice, vi, sub_angle, dist_open)
    ! Calculate the "subtended angle" (i.e. how many degrees of its horizon have
    ! a view of open ocean) and distance-to-open-ocean of a vertex.
    
    IMPLICIT NONE
    
    ! In/output variables
    TYPE(type_mesh),                     INTENT(IN)    :: mesh 
    TYPE(type_ice_model),                INTENT(IN)    :: ice
    INTEGER,                             INTENT(IN)    :: vi
    REAL(dp),                            INTENT(OUT)   :: sub_angle
    REAL(dp),                            INTENT(OUT)   :: dist_open
    
    ! Local variables:
    INTEGER                                            :: thetai
    REAL(dp)                                           :: theta
    INTEGER,  PARAMETER                                :: ntheta            = 16         ! Number of directions we'll look into
    INTEGER,  DIMENSION(:    ), ALLOCATABLE            :: sees_ocean_in_dir
    REAL(dp), DIMENSION(:    ), ALLOCATABLE            :: dist_ocean_in_dir

    ! Only calculate the angle for shelf vertices
    IF (.NOT. ice%mask_shelf( vi) == 1) THEN
      IF (ice%mask_ocean( vi) == 1) THEN
        sub_angle = 360._dp
        dist_open = 0._dp
        RETURN
      ELSE
        sub_angle = 0._dp
        dist_open = mesh%xmax + mesh%ymax - mesh%xmin - mesh%ymin
        RETURN
      END IF
    END IF

    ! Look in 16 directions
    ALLOCATE( sees_ocean_in_dir( ntheta))
    ALLOCATE( dist_ocean_in_dir( ntheta))

    DO thetai = 1, ntheta
      theta = (thetai-1) * 2._dp * pi / ntheta
      CALL look_for_ocean( mesh, ice, vi, theta, sees_ocean_in_dir( thetai), dist_ocean_in_dir( thetai))
    END DO

    sub_angle = SUM(    sees_ocean_in_dir) * 360._dp / ntheta
    dist_open = MINVAL( dist_ocean_in_dir)
    
    DEALLOCATE( sees_ocean_in_dir)
    DEALLOCATE( dist_ocean_in_dir)
    
  END SUBROUTINE calculate_sub_angle_dist_open
  SUBROUTINE look_for_ocean( mesh, ice, vi, theta, sees_ocean, dist_ocean)
    ! Look outward from vertex vi in direction theta and check if we can "see"
    ! open ocean without any land or grounded ice in between, return true (and the distance to this ocean).
    
    IMPLICIT NONE
    
    ! In/output variables
    TYPE(type_mesh),                     INTENT(IN)    :: mesh 
    TYPE(type_ice_model),                INTENT(IN)    :: ice
    INTEGER,                             INTENT(IN)    :: vi
    REAL(dp),                            INTENT(IN)    :: theta
    INTEGER,                             INTENT(OUT)   :: sees_ocean
    REAL(dp),                            INTENT(OUT)   :: dist_ocean
    
    ! Local variables:
    REAL(dp), PARAMETER                                :: max_look_distance = 750000._dp ! Maximum distance to look before we decide no ocean will ever be found.
    REAL(dp), DIMENSION(2)                             :: p, q
    REAL(dp)                                           :: d_min, d, distance_along_line
    INTEGER                                            :: vi_prev, vi_cur, vi_next, ci, vc
    LOGICAL                                            :: Finished

    sees_ocean = 0
    dist_ocean = mesh%xmax + mesh%ymax - mesh%xmin - mesh%ymin

    ! End points of trace
    p = mesh%V( vi,:)
    q = [mesh%V( vi,1) + max_look_distance * COS( theta), &
         mesh%V( vi,2) + max_look_distance * SIN( theta)]

    vi_prev = 0
    vi_cur  = vi

    Finished = .FALSE.
    DO WHILE (.NOT. Finished)

      ! Find the next vertex point the trace. Instead of doing a "real"
      ! mesh transect, just take the neighbour vertex closest to q,
      ! which is good enough for this and is MUCH faster.

      vi_next = 0
      d_min   = mesh%xmax + mesh%ymax - mesh%xmin - mesh%ymin
      DO ci = 1, mesh%nC( vi_cur)
        vc = mesh%C( vi_cur,ci)
        p  = mesh%V( vc,:)
        d  = NORM2( q-p)
        IF (d < d_min) THEN
          d_min = d
          vi_next = vc
        END IF
      END DO
      
      distance_along_line = NORM2( mesh%V( vi_next,:) - mesh%V( vi,:) )

      ! Check if we've finished the trace
      IF (ice%mask_land( vi_next) == 1) THEN
        sees_ocean = 0
        Finished = .TRUE.
      ELSEIF (ice%mask_ocean( vi_next) == 1 .AND. ice%mask_shelf( vi_next) == 0) THEN
        sees_ocean = 1
        dist_ocean = distance_along_line
        Finished = .TRUE.
      ELSEIF (distance_along_line > max_look_distance) THEN
        sees_ocean = 0
        Finished = .TRUE.
      ELSEIF (mesh%edge_index( vi_next) > 0) THEN
        sees_ocean = 0
        Finished = .TRUE.
      ELSEIF (vi_prev == vi_next) THEN
        sees_ocean = 0
        Finished = .TRUE.
      END IF

      ! Move to next vertex
      vi_prev = vi_cur
      vi_cur  = vi_next

    END DO ! DO WHILE (.NOT. Finished)

  END SUBROUTINE look_for_ocean 
  
  ! Administration: allocation, initialisation, and remapping
  SUBROUTINE initialise_BMB_model( mesh, BMB, region_name)
    ! Allocate memory for the data fields of the SMB model.
    
    IMPLICIT NONE
    
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh 
    TYPE(type_BMB_model),                INTENT(INOUT) :: BMB
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    
    ! Local variables:
    CHARACTER(LEN=64), PARAMETER                       :: routine_name = 'initialise_BMB_model'
    INTEGER                                            :: n1, n2
    
    n1 = par%mem%n
    
    IF (par%master) WRITE (0,*) '  Initialising BMB model...'
    
    ! Allocate memory
    CALL allocate_shared_dp_1D( mesh%nV,     BMB%BMB,              BMB%wBMB             )
    CALL allocate_shared_dp_1D( mesh%nV,     BMB%BMB_sheet,        BMB%wBMB_sheet       )
    CALL allocate_shared_dp_1D( mesh%nV,     BMB%BMB_shelf,        BMB%wBMB_shelf       )
    CALL allocate_shared_dp_1D( mesh%nV,     BMB%sub_angle,        BMB%wsub_angle       )
    CALL allocate_shared_dp_1D( mesh%nV,     BMB%dist_open,        BMB%wdist_open       )
    
    ! Tuning parameters
    CALL allocate_shared_dp_0D( BMB%T_ocean_mean_PD,            BMB%wT_ocean_mean_PD           )
    CALL allocate_shared_dp_0D( BMB%T_ocean_mean_cold,          BMB%wT_ocean_mean_cold         )
    CALL allocate_shared_dp_0D( BMB%T_ocean_mean_warm,          BMB%wT_ocean_mean_warm         )
    CALL allocate_shared_dp_0D( BMB%BMB_deepocean_PD,           BMB%wBMB_deepocean_PD          )
    CALL allocate_shared_dp_0D( BMB%BMB_deepocean_cold,         BMB%wBMB_deepocean_cold        )
    CALL allocate_shared_dp_0D( BMB%BMB_deepocean_warm,         BMB%wBMB_deepocean_warm        )
    CALL allocate_shared_dp_0D( BMB%BMB_shelf_exposed_PD,       BMB%wBMB_shelf_exposed_PD      )
    CALL allocate_shared_dp_0D( BMB%BMB_shelf_exposed_cold,     BMB%wBMB_shelf_exposed_cold    )
    CALL allocate_shared_dp_0D( BMB%BMB_shelf_exposed_warm,     BMB%wBMB_shelf_exposed_warm    )
    CALL allocate_shared_dp_0D( BMB%subshelf_melt_factor,       BMB%wsubshelf_melt_factor      )
    CALL allocate_shared_dp_0D( BMB%deep_ocean_threshold_depth, BMB%wdeep_ocean_threshold_depth)
    
    IF (region_name == 'NAM') THEN
      BMB%T_ocean_mean_PD            = C%T_ocean_mean_PD_NAM
      BMB%T_ocean_mean_cold          = C%T_ocean_mean_cold_NAM
      BMB%T_ocean_mean_warm          = C%T_ocean_mean_warm_NAM
      BMB%BMB_deepocean_PD           = C%BMB_deepocean_PD_NAM
      BMB%BMB_deepocean_cold         = C%BMB_deepocean_cold_NAM
      BMB%BMB_deepocean_warm         = C%BMB_deepocean_warm_NAM
      BMB%BMB_shelf_exposed_PD       = C%BMB_shelf_exposed_PD_NAM
      BMB%BMB_shelf_exposed_cold     = C%BMB_shelf_exposed_cold_NAM
      BMB%BMB_shelf_exposed_warm     = C%BMB_shelf_exposed_warm_NAM
      BMB%subshelf_melt_factor       = C%subshelf_melt_factor_NAM
      BMB%deep_ocean_threshold_depth = C%deep_ocean_threshold_depth_NAM
    ELSEIF (region_name == 'EAS') THEN
      BMB%T_ocean_mean_PD            = C%T_ocean_mean_PD_EAS
      BMB%T_ocean_mean_cold          = C%T_ocean_mean_cold_EAS
      BMB%T_ocean_mean_warm          = C%T_ocean_mean_warm_EAS
      BMB%BMB_deepocean_PD           = C%BMB_deepocean_PD_EAS
      BMB%BMB_deepocean_cold         = C%BMB_deepocean_cold_EAS
      BMB%BMB_deepocean_warm         = C%BMB_deepocean_warm_EAS
      BMB%BMB_shelf_exposed_PD       = C%BMB_shelf_exposed_PD_EAS
      BMB%BMB_shelf_exposed_cold     = C%BMB_shelf_exposed_cold_EAS
      BMB%BMB_shelf_exposed_warm     = C%BMB_shelf_exposed_warm_EAS
      BMB%subshelf_melt_factor       = C%subshelf_melt_factor_EAS
      BMB%deep_ocean_threshold_depth = C%deep_ocean_threshold_depth_EAS
    ELSEIF (region_name == 'GRL') THEN
      BMB%T_ocean_mean_PD            = C%T_ocean_mean_PD_GRL
      BMB%T_ocean_mean_cold          = C%T_ocean_mean_cold_GRL
      BMB%T_ocean_mean_warm          = C%T_ocean_mean_warm_GRL
      BMB%BMB_deepocean_PD           = C%BMB_deepocean_PD_GRL
      BMB%BMB_deepocean_cold         = C%BMB_deepocean_cold_GRL
      BMB%BMB_deepocean_warm         = C%BMB_deepocean_warm_GRL
      BMB%BMB_shelf_exposed_PD       = C%BMB_shelf_exposed_PD_GRL
      BMB%BMB_shelf_exposed_cold     = C%BMB_shelf_exposed_cold_GRL
      BMB%BMB_shelf_exposed_warm     = C%BMB_shelf_exposed_warm_GRL
      BMB%subshelf_melt_factor       = C%subshelf_melt_factor_GRL
      BMB%deep_ocean_threshold_depth = C%deep_ocean_threshold_depth_GRL
    ELSEIF (region_name == 'ANT') THEN
      BMB%T_ocean_mean_PD            = C%T_ocean_mean_PD_ANT
      BMB%T_ocean_mean_cold          = C%T_ocean_mean_cold_ANT
      BMB%T_ocean_mean_warm          = C%T_ocean_mean_warm_ANT
      BMB%BMB_deepocean_PD           = C%BMB_deepocean_PD_ANT
      BMB%BMB_deepocean_cold         = C%BMB_deepocean_cold_ANT
      BMB%BMB_deepocean_warm         = C%BMB_deepocean_warm_ANT
      BMB%BMB_shelf_exposed_PD       = C%BMB_shelf_exposed_PD_ANT
      BMB%BMB_shelf_exposed_cold     = C%BMB_shelf_exposed_cold_ANT
      BMB%BMB_shelf_exposed_warm     = C%BMB_shelf_exposed_warm_ANT
      BMB%subshelf_melt_factor       = C%subshelf_melt_factor_ANT
      BMB%deep_ocean_threshold_depth = C%deep_ocean_threshold_depth_ANT
    END IF
    
    n2 = par%mem%n
    CALL write_to_memory_log( routine_name, n1, n2)
      
  END SUBROUTINE initialise_BMB_model
  SUBROUTINE remap_BMB_model( mesh_old, mesh_new, map, BMB)
    ! Remap or reallocate all the data fields
  
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh_old
    TYPE(type_mesh),                     INTENT(IN)    :: mesh_new
    TYPE(type_remapping),                INTENT(IN)    :: map
    TYPE(type_BMB_model),                INTENT(INOUT) :: BMB
    
    ! Local variables:
    INTEGER                                            :: int_dummy
    
    int_dummy = mesh_old%nV
    int_dummy = map%trilin%vi( 1,1)
        
    ! Reallocate rather than remap; after a mesh update we'll immediately run the BMB model anyway
    CALL reallocate_field_dp( mesh_new%nV, BMB%BMB,             BMB%wBMB            )
    CALL reallocate_field_dp( mesh_new%nV, BMB%BMB_sheet,       BMB%wBMB_sheet      )
    CALL reallocate_field_dp( mesh_new%nV, BMB%BMB_shelf,       BMB%wBMB_shelf      )
    CALL reallocate_field_dp( mesh_new%nV, BMB%sub_angle,       BMB%wsub_angle      )
    CALL reallocate_field_dp( mesh_new%nV, BMB%dist_open,       BMB%wdist_open      )
    
  END SUBROUTINE remap_BMB_model
  
END MODULE BMB_module
