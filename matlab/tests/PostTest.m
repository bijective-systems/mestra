classdef PostTest < matlab.unittest.TestCase
%PostTest  Weights, integration and the post-processing helpers.
%
%   Sections 3 and 4 of docs/api-conventions.md.  The four operations
%   that need nothing but the format, and the weight array the
%   specification says is computed from connectivity and never
%   imported.
%
%   See also ConventionsTest, mestra.computeWeights, mestra.integrate.

    methods (Test)

        % ------------------------------- 3. weights

        function cellWeightsAreTheCellMeasure(testCase)
        %cellWeightsAreTheCellMeasure  Two unit squares in the first
        %   instance and two 1.5-by-1 rectangles in the second.
            d = PostTest.family();
            w = mestra.computeWeights(d, 's0', 'cell');
            testCase.verifyEqual(w.role, 'weight');
            testCase.verifyEqual(w.units, 'm2');
            testCase.verifyTrue(w.recomputed, ...
                'W06: a weight is marked as recomputed');
            testCase.verifyEqual(w.varies, 'group:member', ...
                'a weight varies along whatever the coordinates do');
            v = mestra.permute(w.values, w.dims, ...
                               {'group:member', 'cell', 'component'});
            testCase.verifyEqual(squeeze(v), [1 1; 1.5 1.5], ...
                                 'AbsTol', 1e-12);
        end

        function nodeWeightsAreTheLumpedShare(testCase)
        %nodeWeightsAreTheLumpedShare  Every cell gives each of its
        %   nodes an equal part of its own measure, so the node
        %   weights sum to the same total as the cell weights.
            d = PostTest.family();
            w = mestra.computeWeights(d, 's0', 'node');
            v = mestra.permute(w.values, w.dims, ...
                               {'group:member', 'node', 'component'});
            first = squeeze(v(1, :, 1))';
            testCase.verifyEqual(first, [0.25 0.5 0.25 0.25 0.5 0.25]', ...
                                 'AbsTol', 1e-12);
            testCase.verifyEqual(sum(first), 2, 'AbsTol', 1e-12, ...
                'the lumped weights sum to the area of the mesh');
            second = squeeze(v(2, :, 1))';
            testCase.verifyEqual(sum(second), 3, 'AbsTol', 1e-12);
        end

        function theWeightIsStoredAndWritesCleanly(testCase)
        %theWeightIsStoredAndWritesCleanly  It is an array of the
        %   file like any other, and W06 does not fire on it.
            d = PostTest.family();
            mestra.computeWeights(d, 's0', 'cell');
            out = [tempname() '.mes'];
            cleanup = onCleanup(@() PostTest.removeIfPresent(out));
            mestra.write(d, out);
            r = mestra.validate(out);
            testCase.verifyEmpty(r.errors, strjoin(r.errors, ','));
            testCase.verifyFalse(any(strcmp(r.warnings, 'W06')), ...
                'the weight says it was recomputed');
            back = mestra.read(out);
            testCase.verifyEqual(back.cellArray('s0', 'weight').role, ...
                                 'weight');
        end

        function everyCellTypeItClaimsIsMeasured(testCase)
        %everyCellTypeItClaimsIsMeasured  Length, area and volume by
        %   cell type, on shapes whose measure is known by hand.
            M = mestra.internal.Measure;
            testCase.verifyEqual(M.cell(1, [0; 0; 0]), 0, ...
                'a vertex has no measure');
            testCase.verifyEqual(M.cell(3, [0 3; 0 4]), 5, 'AbsTol', 1e-12);
            testCase.verifyEqual(M.cell(5, [0 1 0; 0 0 1]), 0.5, ...
                                 'AbsTol', 1e-12);
            testCase.verifyEqual(M.cell(9, [0 2 2 0; 0 0 3 3]), 6, ...
                                 'AbsTol', 1e-12);
            testCase.verifyEqual(M.cell(7, [0 2 2 0 ; 0 0 3 3]), 6, ...
                                 'AbsTol', 1e-12, 'a polygon of four');
            testCase.verifyEqual(M.cell(10, [0 1 0 0; 0 0 1 0; 0 0 0 1]), ...
                                 1/6, 'AbsTol', 1e-12);
            hex = [0 2 2 0 0 2 2 0; 0 0 3 3 0 0 3 3; 0 0 0 0 4 4 4 4];
            testCase.verifyEqual(M.cell(12, hex), 24, 'AbsTol', 1e-12);
            wedge = [0 1 0 0 1 0; 0 0 1 0 0 1; 0 0 0 2 2 2];
            testCase.verifyEqual(M.cell(13, wedge), 1, 'AbsTol', 1e-12);
            pyr = [0 2 2 0 1; 0 0 3 3 1.5; 0 0 0 0 4];
            testCase.verifyEqual(M.cell(14, pyr), 8, 'AbsTol', 1e-12);
        end

        function aQuadraticCellIsRefusedAndNotApproximated(testCase)
        %aQuadraticCellIsRefusedAndNotApproximated  Its edges are
        %   curved; a corner-node measure would look right and be
        %   wrong, so the call says so instead.
            err = [];
            try
                mestra.internal.Measure.cell(22, zeros(3, 6));
            catch err %#ok<CTCH>
            end
            testCase.verifyNotEmpty(err);
            testCase.verifyEqual(err.identifier, 'mestra:weights');
            testCase.verifySubstring(err.message, 'quadratic');
            testCase.verifySubstring(err.message, 'derived');
        end

        function anUnknownCellTypeIsE21(testCase)
            err = [];
            try
                mestra.internal.Measure.cell(99, zeros(3, 4));
            catch err %#ok<CTCH>
            end
            testCase.verifyEqual(err.identifier, 'mestra:E21');
        end

        function anAxisSupportGetsTrapezoidalNodeWeights(testCase)
        %anAxisSupportGetsTrapezoidalNodeWeights  It has no cells, so
        %   a node's weight is the share of the segments either side
        %   of it, and the weights sum to the length of the axis.
            d = mestra.Dataset();
            d.created = '2026-09-19T00:00:00Z';
            d.addKey('mach', [0.4 0.8], 'condition', '1');
            d.addAxisSupport('a0', [0 0.5 1.0 1.5], 'Hz', ...
                             'Dims', {'component', 'node'});
            w = mestra.computeWeights(d, 'a0', 'node');
            v = mestra.permute(w.values, w.dims, {'node', 'component'});
            testCase.verifyEqual(v(:)', [0.25 0.5 0.5 0.25], ...
                                 'AbsTol', 1e-12);
            testCase.verifyEqual(sum(v(:)), 1.5, 'AbsTol', 1e-12);
            testCase.verifyEqual(w.units, 'Hz');
            err = [];
            try
                mestra.computeWeights(d, 'a0', 'cell');
            catch err %#ok<CTCH>
            end
            testCase.verifySubstring(err.message, 'no cells');
        end

        function integrateUsesTheWeightInTheFile(testCase)
        %integrateUsesTheWeightInTheFile  And picks the instance of a
        %   group-varying weight that belongs to each row.
            d = PostTest.family();
            d.addNodeArray('s0', 'pressure', ...
                           [101 102 103 104 105 106
                            201 202 203 204 205 206], ...
                           'field', 'Pa', 'Dims', {'row', 'node'});
            mestra.computeWeights(d, 's0', 'node');
            out = mestra.integrate(d, 'pressure');
            testCase.verifyEqual(out.weight, 'weight');
            testCase.verifyEqual(out.units, 'Pa m2');
            testCase.verifyEqual(out.dims, {'component', 'row'});
            testCase.verifyEqual(out.values, [207 610.5], 'AbsTol', 1e-9);
        end

        function integrateComputesAWeightAndSaysSo(testCase)
        %integrateComputesAWeightAndSaysSo  Section 3: a file with no
        %   weight array still integrates, and the call says where
        %   the weight came from, rather than refusing for want of one.
            d = PostTest.family();
            d.addNodeArray('s0', 'pressure', ...
                           [101 102 103 104 105 106
                            201 202 203 204 205 206], ...
                           'field', 'Pa', 'Dims', {'row', 'node'});
            out = testCase.verifyWarning(@() mestra.integrate(d, 'pressure'), ...
                                         'mestra:weightComputed');
            testCase.verifyEqual(out.weight, '(computed)');
            testCase.verifyEqual(out.values, [207 610.5], 'AbsTol', 1e-9);
            stored = d.support('s0').nodeArrays;
            testCase.verifyEmpty(stored(strcmp({stored.role}, 'weight')), ...
                'nothing was stored in the file');
        end

        function integrateTakesAWeightByName(testCase)
            d = PostTest.family();
            d.addNodeArray('s0', 'pressure', ones(2, 6), 'field', 'Pa', ...
                           'Dims', {'row', 'node'});
            mestra.computeWeights(d, 's0', 'node', 'Name', 'area');
            out = mestra.integrate(d, 'pressure', 'Weight', 'area');
            testCase.verifyEqual(out.weight, 'area');
            testCase.verifyEqual(out.values(1, 1), 2, 'AbsTol', 1e-12);
            err = [];
            try
                mestra.integrate(d, 'pressure', 'Weight', 'nothing');
            catch err %#ok<CTCH>
            end
            testCase.verifySubstring(err.message, 'mestra.computeWeights');
        end

        % ------------------------------- 4. post-processing

        function aPredictionFromStoredDataAndFromACallable(testCase)
        %aPredictionFromStoredDataAndFromACallable  One question of a
        %   stored slot and of a served one, the same record.
            d = mestra.read(fullfile(corpusRoot(), 'band_stored', 'case.mes'));
            r = mestra.prediction(d, 'pressure');
            testCase.verifyEqual(r.mean.shape, [2 6 1]);
            testCase.verifyEqual(r.uncertainty.data(2, 4, 1), 0.8);
            testCase.verifyEqual(r.level, 0.95);
            testCase.verifyTrue(startsWith(r.method, ...
                                'half-width of a 95 % interval'));
            testCase.verifyError(@() mestra.prediction(d, 'pressure_band'), ...
                                 'mestra:prediction');
            testCase.verifyError(@() mestra.prediction(d, 'pressure', ...
                table(0.5, 'VariableNames', {'mach'})), 'mestra:prediction');
            two = mestra.read(fullfile(corpusRoot(), 'mesh_two_rows', ...
                                       'case.mes'));
            plain = mestra.prediction(two, 'cl');
            testCase.verifyEqual(plain.mean.data, [0.25; 0.55]);
            testCase.verifyEmpty(plain.uncertainty);
            m = mestra.read(fullfile(corpusRoot(), 'affine_band', 'case.mes'));
            t = table(0.5, 4.0, 'VariableNames', {'mach', 'alpha'});
            served = mestra.prediction(m, 'cl', t);
            testCase.verifyEqual(served.mean.data, 1.45);
            testCase.verifyEqual(served.uncertainty.data, 0.02);
            testCase.verifyEqual(served.level, 0.95);
            testCase.verifyError(@() mestra.prediction(m, 'cl'), ...
                                 'mestra:prediction');
            withRows = mestra.read(fullfile(corpusRoot(), ...
                                            'affine_with_rows', 'case.mes'));
            onRows = mestra.prediction(withRows, 'pressure');
            testCase.verifyEqual(onRows.mean.shape, [2 6 1]);
        end

        function fieldStatisticsHasNoGroupingColumnWithoutBy(testCase)
        %fieldStatisticsHasNoGroupingColumnWithoutBy  Section 4: no
        %   column at all, and never one called after somebody
        %   else's example label.
            d = PostTest.withPressure();
            t = mestra.fieldStatistics(d, 'pressure');
            testCase.verifyEqual(t.Properties.VariableNames, ...
                {'row', 'count', 'min', 'max', 'mean', 'std'});
            testCase.verifyEqual(height(t), 2);
            testCase.verifyEqual(t.row', [0 1], ...
                'rows are the file''s, counted from 0');
            testCase.verifyEqual(t.mean', [103.5 203.5], 'AbsTol', 1e-12);
            testCase.verifyEqual(t.min', [101 201]);
            testCase.verifyEqual(t.count', [6 6]);
        end

        function theGroupingColumnIsNamedAfterTheLabel(testCase)
        %theGroupingColumnIsNamedAfterTheLabel  Section 4: keyed by
        %   the label's name, never by a fixed word.
            d = PostTest.withPressure();
            t = mestra.fieldStatistics(d, 'pressure', 'By', 'cad_face_id');
            testCase.verifyEqual(t.Properties.VariableNames, ...
                {'row', 'cad_face_id', 'count', 'min', 'max', 'mean', 'std'});
            testCase.verifyEqual(height(t), 4);
            testCase.verifyEqual(t.cad_face_id', ...
                                 ["upper" "lower" "upper" "lower"], ...
                'a label with a table is reported by its entries');
            testCase.verifyEqual(t.mean', [102 105 202 205], 'AbsTol', 1e-12);
        end

        function aLabelWithNoTableIsItsOwnCategory(testCase)
        %aLabelWithNoTableIsItsOwnCategory  Section 3 says the values
        %   of a label with no table are their own categories.
            d = PostTest.withPressure();
            d.addNodeArray('s0', 'topo', int32([7 7 7 9 9 9]), 'label', ...
                           'Dims', {'component', 'node'});
            t = mestra.fieldStatistics(d, 'pressure', 'By', 'topo');
            testCase.verifyEqual(unique(t.topo)', ["7" "9"]);
        end

        function fieldStatisticsReportsOverScalars(testCase)
        %fieldStatisticsReportsOverScalars  A scalars-only file is a
        %   first-class case, and the one verb that suits it must
        %   apply to it.
            d = mestra.read(fullfile(corpusRoot(), 'scalars_only', ...
                                     'case.mes'));
            t = mestra.fieldStatistics(d, 'cl');
            testCase.verifyEqual(height(t), 1);
            testCase.verifyEqual(t.count, 6);
            g = mestra.fieldStatistics(d, 'cl', 'By', 'geometry');
            testCase.verifyEqual(height(g), 3);
            testCase.verifyEqual(g.Properties.VariableNames{1}, 'geometry');
            testCase.verifyEqual(sum(g.count), 6);
        end

        function timeSeriesFollowsOneTrajectory(testCase)
        %timeSeriesFollowsOneTrajectory  Section 4: one node, one
        %   trajectory, in time order.
            d = mestra.read(fullfile(corpusRoot(), 'transient_fixed_mesh', ...
                                     'case.mes'));
            t = mestra.timeSeries(d, 'u', 4, 'r000');
            testCase.verifyEqual(t.Properties.VariableNames, ...
                                 {'row', 'time', 'value'});
            testCase.verifyEqual(t.row', [0 1 2]);
            testCase.verifyEqual(t.time', [0 0.1 0.3], 'AbsTol', 1e-12);
            testCase.verifyTrue(all(diff(t.time) > 0), ...
                'time increases within a trajectory (E09)');

            other = mestra.timeSeries(d, 'u', 4, 'r001');
            testCase.verifyEqual(other.row', [3 4]);
            testCase.verifyEqual(other.value', [333 343], 'AbsTol', 1e-9);
        end

        function timeSeriesNamesTheTrajectoriesItHas(testCase)
            d = mestra.read(fullfile(corpusRoot(), 'transient_fixed_mesh', ...
                                     'case.mes'));
            err = [];
            try
                mestra.timeSeries(d, 'u', 4, 'nope');
            catch err %#ok<CTCH>
            end
            testCase.verifyEqual(err.identifier, 'mestra:timeSeries');
            testCase.verifySubstring(err.message, 'r000');
            testCase.verifyEqual(mestra.timeSeries(d, 'u', 4, 1).row', [3 4], ...
                'a trajectory may also be named by its id');
        end

        function aFileWithNoTimeKeyHasNoTimeSeries(testCase)
            d = mestra.read(fullfile(corpusRoot(), 'mesh_two_rows', ...
                                     'case.mes'));
            err = [];
            try
                mestra.timeSeries(d, 'pressure', 1);
            catch err %#ok<CTCH>
            end
            testCase.verifyEqual(err.identifier, 'mestra:timeSeries');
            testCase.verifySubstring(err.message, 'role time');
        end

        function groupedSplitKeepsEveryUnitWhole(testCase)
        %groupedSplitKeepsEveryUnitWhole  Section 4.  No unit of
        %   generalisation is ever on two sides; that is the whole
        %   purpose of the call.
            d = mestra.read(fullfile(corpusRoot(), 'scalars_only', ...
                                     'case.mes'));
            g = double(d.key('geometry').values);
            for seed = 0:9
                s = mestra.groupedSplit(d, ...
                        struct('train', 0.8, 'test', 0.2), 'Seed', seed);
                testCase.verifyEqual(sort([s.train s.test]), 1:numel(g));
                testCase.verifyEmpty(intersect(unique(g(s.train)), ...
                                               unique(g(s.test))), ...
                    'a geometry is never on both sides');
            end
        end

        function groupedSplitNeverReturnsAnEmptyPart(testCase)
        %groupedSplitNeverReturnsAnEmptyPart  Section 4: with at
        %   least as many units as parts, every named part gets one.
            d = mestra.read(fullfile(corpusRoot(), 'scalars_only', ...
                                     'case.mes'));
            s = mestra.groupedSplit(d, struct('train', 0.99, ...
                                              'validation', 0.005, ...
                                              'test', 0.005));
            testCase.verifyNotEmpty(s.train);
            testCase.verifyNotEmpty(s.validation);
            testCase.verifyNotEmpty(s.test);
        end

        function groupedSplitRefusesWhenItCannotDivide(testCase)
        %groupedSplitRefusesWhenItCannotDivide  Fewer units than
        %   parts is refused, and says how many units there are,
        %   rather than handing back an empty part.
            d = mestra.read(fullfile(corpusRoot(), 'scalars_only', ...
                                     'case.mes'));
            err = [];
            try
                mestra.groupedSplit(d, struct('a', 1, 'b', 1, 'c', 1, ...
                                              'd', 1));
            catch err %#ok<CTCH>
            end
            testCase.verifyEqual(err.identifier, 'mestra:groupedSplit');
            testCase.verifySubstring(err.message, '3 unit(s)');
        end

        function groupedSplitRefusesWithoutAUnitOfGeneralisation(testCase)
        %groupedSplitRefusesWithoutAUnitOfGeneralisation  Section 4.
            d = mestra.read(fullfile(corpusRoot(), 'labels_tables', ...
                                     'case.mes'));
            err = [];
            try
                mestra.groupedSplit(d, struct('train', 0.8, 'test', 0.2));
            catch err %#ok<CTCH>
            end
            testCase.verifyEqual(err.identifier, 'mestra:groupedSplit');
            testCase.verifySubstring(err.message, 'setGeneralisationGroup');
        end

        function groupedSplitIsTheSameSplitForTheSameSeed(testCase)
        %groupedSplitIsTheSameSplitForTheSameSeed  Section 4 asks for
        %   a seed with a documented default; the default is 0 and
        %   the generator is this package's own, so MATLAB's global
        %   random state does not move the answer.
            d = mestra.read(fullfile(corpusRoot(), 'scalars_only', ...
                                     'case.mes'));
            rng(1);
            a = mestra.groupedSplit(d, struct('train', 0.5, 'test', 0.5));
            rng(99);
            b = mestra.groupedSplit(d, struct('train', 0.5, 'test', 0.5), ...
                                    'Seed', 0);
            testCase.verifyEqual(b, a, 'the default seed is 0');
            seen = {};
            for seed = 0:19
                s = mestra.groupedSplit(d, ...
                        struct('train', 0.5, 'test', 0.5), 'Seed', seed);
                seen{end + 1} = mat2str(s.test); %#ok<AGROW>
            end
            testCase.verifyEqual(numel(unique(seen)), 3, ...
                'the seed reaches every split of three units into 2 and 1');
        end

        function groupedSplitReproducesTheWorkedExample(testCase)
        %groupedSplitReproducesTheWorkedExample  Section 31 ends in a
        %   table: five rotors whose category table is written in an
        %   order that is not their name order, seed 0, 0.8 train and
        %   0.2 test, and test is rotor_c.  An implementation that
        %   reproduces that table reproduces every split, because
        %   nothing else in the algorithm depends on the file.
            d = PostTest.rotors();
            s = mestra.groupedSplit(d, struct('train', 0.8, 'test', 0.2), ...
                                    'Seed', 0);
            testCase.verifyEqual(s.test, [4 9], ...
                'test is rotor_c, whose rows are 4 and 9');
            testCase.verifyEqual(s.train, [1 2 3 5 6 7 8 10]);
            testCase.verifyEqual(reshape(fieldnames(s), 1, []), ...
                {'test', 'train'}, ...
                'the parts come back in part-name order, not the caller''s');
        end

        function groupedSplitSortsTheUnitsByTheirDraws(testCase)
        %groupedSplitSortsTheUnitsByTheirDraws  The same five units
        %   into five parts of one unit each, which makes the order
        %   the draws put them in visible: section 31 sorts them
        %   rotor_c, rotor_e, rotor_b, rotor_a, rotor_d, and the
        %   parts are filled in name order.  This is the splitmix64
        %   stream of the section's draw table, unit by unit.
            d = PostTest.rotors();
            s = mestra.groupedSplit(d, struct('a', 1, 'b', 1, 'c', 1, ...
                                              'd', 1, 'e', 1), 'Seed', 0);
            % rotor_b is id 0, rotor_a is 1, rotor_d is 2, rotor_c is 3
            % and rotor_e is 4; each holds rows id + 1 and id + 6.
            testCase.verifyEqual({s.a, s.b, s.c, s.d, s.e}, ...
                {[4 9], [5 10], [1 6], [2 7], [3 8]});
        end

        function groupedSplitIgnoresTheOrderTheTableWasWrittenIn(testCase)
        %groupedSplitIgnoresTheOrderTheTableWasWrittenIn  Section 31:
        %   two files that hold the same units in tables written in
        %   two orders must split the same way, so the unit order is
        %   the entries' and never the ids'.
            d = PostTest.rotors();
            e = mestra.Dataset();
            e.addCategoryTable('rotor', {'rotor_a', 'rotor_b', 'rotor_c', ...
                                         'rotor_d', 'rotor_e'});
            e.addKey('rotor', int32([1 0 3 2 4 1 0 3 2 4]), 'group', ...
                     'Category', 'rotor');
            e.setGeneralisationGroup('rotor');
            f = struct('train', 0.8, 'test', 0.2);
            testCase.verifyEqual(mestra.groupedSplit(e, f), ...
                                 mestra.groupedSplit(d, f));
        end

        function fractionsComeInThreeShapes(testCase)
            d = mestra.read(fullfile(corpusRoot(), 'scalars_only', ...
                                     'case.mes'));
            a = mestra.groupedSplit(d, struct('train', 0.5, 'test', 0.5));
            b = mestra.groupedSplit(d, {'train', 0.5, 'test', 0.5});
            m = containers.Map({'train', 'test'}, {0.5, 0.5});
            c = mestra.groupedSplit(d, m);
            testCase.verifyEqual(b, a);
            testCase.verifyEqual(sort([c.train c.test]), 1:6);
        end
    end

    methods (Static)

        function d = rotors()
        %rotors  The file of the worked example in section 31: five
        %   units, two rows each, whose category table is written in
        %   an order that is not their name order, so that a reading
        %   of the algorithm that orders by id gives another answer.
            d = mestra.Dataset();
            d.writer = 'mestra matlab tests';
            d.created = '2026-09-19T00:00:00Z';
            d.addCategoryTable('rotor', {'rotor_b', 'rotor_a', 'rotor_d', ...
                                         'rotor_c', 'rotor_e'});
            d.addKey('rotor', int32([0 1 2 3 4 0 1 2 3 4]), 'group', ...
                     'Category', 'rotor');
            d.setGeneralisationGroup('rotor');
        end

        function d = family()
        %family  Two members, six nodes, two quadrilateral cells.
            d = mestra.Dataset();
            d.writer = 'mestra matlab tests';
            d.created = '2026-09-19T00:00:00Z';
            d.addCategoryTable('member', {'wing_a', 'wing_b'});
            d.addKey('mach', [0.4 0.8], 'condition', '1');
            d.addKey('member', int32([0 1]), 'group', 'Category', 'member');
            d.setGeneralisationGroup('member');
            coords = cat(3, [0 1 2 0 1 2; 0 0 0 1 1 1], ...
                            [0 1.5 3 0 1.5 3; 0 0 0 1 1 1]);
            d.addMeshSupport('s0', coords, uint8([9 9]), int64([0 4 8]), ...
                             int64([0 1 4 3 1 2 5 4]), 'm', ...
                             'Dims', {'component', 'node', 'group:member'});
        end

        function d = withPressure()
        %withPressure  The same, with a field and a labelled surface.
            d = PostTest.family();
            d.addCategoryTable('faces', {'upper', 'lower'});
            d.addNodeArray('s0', 'pressure', ...
                           [101 102 103 104 105 106
                            201 202 203 204 205 206], ...
                           'field', 'Pa', 'Dims', {'row', 'node'});
            d.addNodeArray('s0', 'cad_face_id', int32([0 0 0 1 1 1]), ...
                           'label', 'Category', 'faces', ...
                           'Dims', {'component', 'node'});
        end

        function removeIfPresent(path)
            if exist(path, 'file') == 2
                delete(path);
            end
        end
    end
end
