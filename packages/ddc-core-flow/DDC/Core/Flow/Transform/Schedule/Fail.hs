
module DDC.Core.Flow.Transform.Schedule.Fail
        (Fail (..))
where
import DDC.Core.Flow.Exp
import DDC.Core.Flow.Prim
import DDC.Core.Flow.Process.Operator


-- | Reason a process kernel could not be scheduled into a procedure.
data Fail
        -- | Process has no rate parameters.
        = FailNoRateParameters

        -- | Process has no series parameters, 
        --   but there needs to be at least one.
        | FailNoSeriesParameters

        -- | Process has series of different rates,
        --   but all series must have the same rate.
        | FailMultipleRates

        -- | Primary rate variable of the process does not match
        --   the rate of the paramter series.
        | FailPrimaryRateMismatch

        -- | Cannot lift expression to vector operators.
        | FailCannotLiftExp  (Exp () Name)

        -- | Cannot lift type to vector type.
        | FailCannotLiftType (Type Name)

        -- | Current scheduler does not support this operator.
        | FailUnsupported Operator
        deriving Show
