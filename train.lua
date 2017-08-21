--[[
    Script for training a human activty estimator network.
--]]

require 'paths'
require 'torch'
require 'string'
require 'optim'

local tnt = require 'torchnet'
local Logger = optim.Logger


--------------------------------------------------------------------------------
-- Load configs (data, model, criterion, optimState)
--------------------------------------------------------------------------------

print('==> (1/3) Load configurations: ')
paths.dofile('configs.lua')

-- load model + criterion
print('==> (2/3) Load/create network: ')
load_model('train')

utils.print_model_to_txt(paths.concat(opt.save, 'architecture.txt'),
                         {
                             {'==> Features network:', model_features},
                             {'==> Body Joint kps network:', model_kps},
                             {'==> Classifier network:', model_classifier}
                         })


-- set local vars
local lopt = opt
local nBatchesTrain = opt.trainIters
local nBatchesTest = opt.testIters

-- convert modules to a specified tensor type
local function cast(x) return x:type(opt.dataType) end

print('==> (3/3) Train the network on the dataset: ' .. opt.dataset)

print('\n**********************')
print('Optimizer: ' .. opt.optMethod)
print('**********************\n')


--------------------------------------------------------------------------------
-- Setup data generator
--------------------------------------------------------------------------------

local function getIterator(mode)
    return tnt.ParallelDatasetIterator{
        nthread = opt.nThreads,
        init    = function(threadid)
                    require 'torch'
                    require 'torchnet'
                    opt = lopt
                    paths.dofile('data.lua')
                    paths.dofile('sample_batch.lua')
                    torch.manualSeed(threadid+opt.manualSeed)
                  end,
        closure = function()

            -- setup data loader
            local data_loader = select_dataset_loader(opt.dataset, mode)
            local loader = data_loader[mode]

            -- number of iterations
            local nIters = (mode=='train' and opt.trainIters) or opt.testIters

            -- setup dataset iterator
            return tnt.ListDataset{
                list = torch.range(1, nIters):long(),
                load = function(idx)
                    local input_kps, input_feats, label = getSampleBatch(loader, opt.batchSize, mode=='train')
                    return {
                        input_kps = input_kps,
                        input_feats = input_feats,
                        target = label
                    }
                end
            }:batch(1, 'include-last')
        end,
    }
end


--------------------------------------------------------------------------------
-- Setup torchnet engine/meters/loggers
--------------------------------------------------------------------------------

local timers = {
   batchTimer = torch.Timer(),
   dataTimer = torch.Timer(),
   epochTimer = torch.Timer(),
}

local meters = {
    test = tnt.AverageValueMeter(),
    train = tnt.AverageValueMeter(),
    train_clerr = tnt.ClassErrorMeter{topk = {1,5},accuracy=true},
    clerr = tnt.ClassErrorMeter{topk = {1,5},accuracy=true},
    ap = tnt.APMeter(),
}

function meters:reset()
    self.test:reset()
    self.train:reset()
    self.train_clerr:reset()
    self.clerr:reset()
    self.ap:reset()
end

local loggers = {
    test = Logger(paths.concat(opt.save,'test.log'), opt.continue),
    train = Logger(paths.concat(opt.save,'train.log'), opt.continue),
    full_train = Logger(paths.concat(opt.save,'full_train.log'), opt.continue),
}

loggers.test:setNames{'Test Loss', 'Test acc.', 'Test mAP'}
loggers.train:setNames{'Train Loss', 'Train acc.'}
loggers.full_train:setNames{'Train Loss', 'Train accuracy'}

loggers.test.showPlot = false
loggers.train.showPlot = false
loggers.full_train.showPlot = false


-- set up training engine:
local engine = tnt.OptimEngine()

engine.hooks.onStart = function(state)
    if state.training then
        state.config = optimStateFn(state.epoch+1)
        if opt.epochNumber>1 then
            state.epoch = math.max(opt.epochNumber, state.epoch)
        end
    end
end


engine.hooks.onStartEpoch = function(state)
    print('\n**********************************************')
    print(('Starting Train epoch %d/%d  %s'):format(state.epoch+1, state.maxepoch,  opt.save))
    print('**********************************************')
    state.config = optimStateFn(state.epoch+1)
    state.network:training()  -- ensure the model is set to training mode
    timers.epochTimer:reset()
end


-- copy sample to GPU buffer:
local inputs, targets = cast(torch.Tensor()), cast(torch.Tensor())
engine.hooks.onSample = function(state)
    cutorch.synchronize(); collectgarbage();

    local num_batches = state.sample.input_feats[1]:size(1)
    local num_imgs_seq = state.sample.input_feats[1]:size(2)

    --------
    local function process_inputs(model, input)
        local features = {}
        if model then
            local batch_feats_imgs = {}
            for ibatch=1, num_batches do
                local seq_feats = {}
                for i=1, num_imgs_seq do
                    local img = input[ibatch][i]
                    local img_cuda = img:view(1, unpack(img:size():totable())):cuda()  -- extra dimension for cudnn batchnorm
                    local features = model:forward(img_cuda)
                    table.insert(seq_feats, features)
                end
                -- convert table into a single tensor
                table.insert(batch_feats_imgs, nn.Unsqueeze(1):cuda():forward(nn.JoinTable(1):cuda():forward(seq_feats)))
            end
            -- convert table into a single tensor
            features = nn.JoinTable(1):cuda():forward(batch_feats_imgs)
        end
        return features
    end
    --------

    -- process images features
    local inputs_features = process_inputs(model_features, state.sample.input_feats[1])
    local inputs_kps = process_inputs(model_kps, state.sample.input_kps[1])
    if string.find(opt.netType, 'vgg16') and string.find(opt.netType, 'kps') then
        state.sample.input = {inputs_features, inputs_kps}
    elseif string.find(opt.netType, 'vgg16') then
        state.sample.input = inputs_features
    elseif string.find(opt.netType, 'kps') then
        state.sample.input = inputs_kps
    else
        error('Invalid network type: ' .. opt.netType)
    end

    -- copy data to targets
    targets:resize(state.sample.target[1]:size() ):copy(state.sample.target[1])
    if string.find(opt.netType, 'lstm') then
        state.sample.target = targets:view(-1)
    elseif string.find(opt.netType, 'convnet') then
        state.sample.target = targets[{{},{1}}]:squeeze(2):contiguous()
    else
        error('Invalid network type: ' .. opt.netType)
    end

    timers.dataTimer:stop()
    timers.batchTimer:reset()
end


engine.hooks.onForward = function(state)
   if not state.training then
      xlua.progress(state.t, nBatchesTest)
   end
end


engine.hooks.onUpdate = function(state)
    timers.dataTimer:reset()
    timers.dataTimer:resume()
end


engine.hooks.onForwardCriterion = function(state)
    if state.training then
        meters.train:add(state.criterion.output)
        meters.train_clerr:add(state.network.output,state.sample.target)
        if opt.verbose then
            print(string.format('epoch[%d/%d][%d/%d][batch=%d] - loss: %2.4f; top-1 err: ' ..
                                '%2.2f; top-5 err: %2.2f; lr = %2.2e;  DataLoadingTime: %0.5f; ' ..
                                'forward-backward time: %0.5f', state.epoch+1, state.maxepoch,
                                state.t+1, nBatchesTrain, opt.batchSize, meters.train:value(),
                                100-meters.train_clerr:value{k = 1}, 100-meters.train_clerr:value{k = 5},
                                state.config.learningRate, timers.dataTimer:time().real,
                                timers.batchTimer:time().real))
        else
            xlua.progress(state.t+1, nBatchesTrain)
        end

        loggers.full_train:add{state.criterion.output}
    else
        meters.clerr:add(state.network.output,state.sample.target)
        meters.test:add(state.criterion.output)
        local tar = torch.ByteTensor(#state.network.output):fill(0)
        for k=1,state.sample.target:size(1) do
            local id = state.sample.target[k]
            tar[k][id]=1
        end
        meters.ap:add(state.network.output,tar)
    end
end


--[[ Gradient clipping to try to prevent the gradient from exploding. ]]--
-- ref: https://github.com/facebookresearch/torch-rnnlib/blob/master/examples/word-language-model/word_lm.lua#L216-L233
local function clipGradients(grads, norm)
    local totalnorm = grads:norm()
    if totalnorm > norm then
        local coeff = norm / math.max(totalnorm, 1e-6)
        grads:mul(coeff)
    end
end
engine.hooks.onBackward = function(state)
    if opt.grad_clip > 0 then
        clipGradients(state.gradParams, opt.grad_clip)
    end
end


local test_best_accu = 0
engine.hooks.onEndEpoch = function(state)
    ---------------------------------
    -- measure test loss and error:
    ---------------------------------

    print("Epoch Train Loss:" ,meters.train:value(),"Total Epoch time: ",timers.epochTimer:time().real)
    print("Accuracy: Top 1%", meters.train_clerr:value{k = 1} .. '%')
    print("Accuracy: Top 5%", meters.train_clerr:value{k = 5} .. '%')
    -- measure test loss and error:
    loggers.train:add{meters.train:value(),meters.train_clerr:value()[1]}
    meters:reset()
    state.t = 0


    ---------------------
    -- test the network
    ---------------------

    local accuracy_top1
    if nBatchesTest > 0 then
        print('\n**********************************************')
        print(('Test network (epoch = %d/%d)'):format(state.epoch, state.maxepoch))
        print('**********************************************')
        engine:test{
            network   = model_classifier,
            iterator  = getIterator('test'),
            criterion = criterion,
        }

        loggers.test:add{meters.test:value(),meters.clerr:value()[1],meters.ap:value():mean()}
        print("Test Loss" , meters.test:value())
        print("Accuracy: Top 1%", meters.clerr:value{k = 1} .. '%')
        print("Accuracy: Top 5%", meters.clerr:value{k = 5} .. '%')
        print("mean AP:",meters.ap:value():mean())
        accuracy_top1 = meters.clerr:value{k = 1}
    end

    --------------------------------
    -- save model snapshots to disk
    --------------------------------

    storeModel(model_features, model_kps, state.network, state.config, state.epoch, opt)

    ------------------------------------
    -- save best accuracy model to disk
    ------------------------------------

    if accuracy_top1 > test_best_accu and opt.saveBest then
        test_best_accu = accuracy_top1
        storeModelBest(model_features, model_kps, state.network, opt)
    end

    timers.epochTimer:reset()
    state.t = 0
end


--------------------------------------------------------------------------------
-- Train the model
--------------------------------------------------------------------------------

print('==> Train network model')
engine:train{
    network   = model_classifier,
    iterator  = getIterator('train'),
    criterion = criterion,
    optimMethod = optim[opt.optMethod],
    config = optimStateFn(1),
    maxepoch = nEpochs
}


--------------------------------------------------------------------------------
-- Plot log graphs
--------------------------------------------------------------------------------

loggers.test:style{'+-', '+-'}; loggers.test:plot()
loggers.train:style{'+-', '+-'}; loggers.train:plot()
loggers.full_train:style{'-', '-'}; loggers.full_train:plot()

print('==> Script complete.')