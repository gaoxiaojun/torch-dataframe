--[[
Copyright (c) 2016-present, Facebook, Inc.
All rights reserved.
This source code is licensed under the BSD-style license found in the
LICENSE file in the Facebook license of this file. An additional grant
of patent rights can be found in the PATENTS file in the same directory.
]]--
-- load torchnet:
local tnt = require 'torchnet'

require 'Dataframe'

-- use GPU or not:
local cmd = torch.CmdLine()
cmd:option('-usegpu', false, 'use gpu for training')
local config = cmd:parse(arg)
print(string.format('running on %s', config.usegpu and 'GPU' or 'CPU'))

-- function that sets of dataset iterator:
local function getIterator(mode)
   -- load MNIST dataset:
   local mnist = require 'mnist'
   local dataset = mnist[mode .. 'dataset']()
   local ext_resource = dataset.data:reshape(dataset.data:size(1),
      dataset.data:size(2) * dataset.data:size(3)):double()

   -- Create a Dataframe with the label. The actual images will be loaded
   --  as an external resource
   local df = Dataframe(
      Df_Dict{
         label = dataset.label:totable(),
         row_id = torch.range(1, dataset.data:size(1)):totable()
      })

   -- Since the mnist package already has taken care of the data
   --  splitting we create a single subsetter
   df:create_subsets{
      subsets = Df_Dict{core = 1},
      class_args = Df_Tbl({
         batch_args = Df_Tbl({
            label = Df_Array("label"),
            data = function(row)
               return ext_resource[row.row_id]
            end
         })
      })
   }

   return df["/core"]:get_iterator{
      batch_size = 128,
      target_transform = function(val)
         return val + 1
      end
   }
end

-- set up logistic regressor:
local net = nn.Sequential():add(nn.Linear(784,10))
local criterion = nn.CrossEntropyCriterion()

-- set up training engine:
local engine = tnt.SGDEngine()
local meter  = tnt.AverageValueMeter()
local clerr  = tnt.ClassErrorMeter{topk = {1}}
engine.hooks.onStartEpoch = function(state)
   meter:reset()
   clerr:reset()
end
engine.hooks.onForwardCriterion = function(state)
   meter:add(state.criterion.output)
   clerr:add(state.network.output, state.sample.target)
   if state.training then
      print(string.format('avg. loss: %2.4f; avg. error: %2.4f',
         meter:value(), clerr:value{k = 1}))
   end
end

-- set up GPU training:
if config.usegpu then

   -- copy model to GPU:
   require 'cunn'
   net       = net:cuda()
   criterion = criterion:cuda()

   -- copy sample to GPU buffer:
   local igpu, tgpu = torch.CudaTensor(), torch.CudaTensor()
   engine.hooks.onSample = function(state)
      igpu:resize(state.sample.input:size() ):copy(state.sample.input)
      tgpu:resize(state.sample.target:size()):copy(state.sample.target)
      state.sample.input  = igpu
      state.sample.target = tgpu
   end  -- alternatively, this logic can be implemented via a TransformDataset
end

-- train the model:
engine:train{
   network   = net,
   iterator  = getIterator('train'),
   criterion = criterion,
   lr        = 0.2,
   maxepoch  = 5,
}

-- measure test loss and error:
meter:reset()
clerr:reset()
engine:test{
   network   = net,
   iterator  = getIterator('test'),
   criterion = criterion,
}
print(string.format('test loss: %2.4f; test error: %2.4f',
   meter:value(), clerr:value{k = 1}))
