module FrontEnd.TiData where

import Data.Map as Map

import FrontEnd.Tc.Type
import HsSyn
import Name.Name
import Options
import Representation

-- Extra data produced by the front end, used to fill in the Ho file.
data TiData = TiData {
    tiDataLiftedInstances :: Map.Map Name HsDecl,
    tiDataModules :: [(Module,HsModule)],
    tiModuleOptions :: [(Module,Opt)],
    tiCheckedRules :: [Rule],
    tiAllAssumptions :: Map.Map Name Scheme
}
